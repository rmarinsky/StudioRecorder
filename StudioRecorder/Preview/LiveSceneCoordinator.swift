@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import AppKit
import CoreImage
import Foundation
import SwiftUI

enum LiveScenePolicy {
    static func shouldRun(route: MainRoute, captureState: RecordingState) -> Bool {
        guard route == .studio else { return false }
        return switch captureState {
        case .ready, .preparing, .recording, .paused, .stopping:
            true
        case .failed:
            false
        }
    }

    static func shouldRunDraftCamera(route: MainRoute, captureState: RecordingState) -> Bool {
        shouldRun(route: route, captureState: captureState)
    }

    static func shouldPreserveCameraSession(captureState: RecordingState) -> Bool {
        switch captureState {
        case .preparing, .recording, .paused, .stopping:
            true
        case .ready, .failed:
            false
        }
    }
}

enum LiveSceneSnapshotCaptureError: LocalizedError, Equatable {
    case screenUnavailable
    case cameraUnavailable

    var errorDescription: String? {
        switch self {
        case .screenUnavailable:
            "The selected screen is not ready for a snapshot yet."
        case .cameraUnavailable:
            "The selected camera is still starting. Try the snapshot again in a moment."
        }
    }

    static func cameraFrame(
        capturesCamera: Bool,
        cameraIsVisible: Bool,
        availableFrame: CVPixelBuffer?
    ) throws -> CVPixelBuffer? {
        guard capturesCamera, cameraIsVisible else { return nil }
        guard let availableFrame else { throw Self.cameraUnavailable }
        return availableFrame
    }
}

private struct CameraFrameState {
    var outputID: ObjectIdentifier?
    var pixelBuffer: CVPixelBuffer?
}

struct LiveProgramPreviewFrame {
    var image: NSImage?
    var presentation: CapturePresentationSnapshot?
}

final class LatestAsyncTaskQueue: @unchecked Sendable {
    typealias Operation = @Sendable () async -> Void

    private let lock = NSLock()
    private var isRunning = false
    private var pending: Operation?
    private var flushWaiters: [CheckedContinuation<Void, Never>] = []

    func enqueue(_ operation: @escaping Operation) {
        let shouldStart = lock.withLock { () -> Bool in
            pending = operation
            guard !isRunning else { return false }
            isRunning = true
            return true
        }
        guard shouldStart else { return }
        Task { await drain() }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            let isIdle = lock.withLock { () -> Bool in
                guard isRunning || pending != nil else { return true }
                flushWaiters.append(continuation)
                return false
            }
            if isIdle { continuation.resume() }
        }
    }

    private func drain() async {
        while let operation = nextOperation() {
            await operation()
        }
    }

    private func nextOperation() -> Operation? {
        var completedWaiters: [CheckedContinuation<Void, Never>] = []
        let operation = lock.withLock { () -> Operation? in
            if let pending {
                self.pending = nil
                return pending
            }
            isRunning = false
            completedWaiters = flushWaiters
            flushWaiters.removeAll()
            return nil
        }
        completedWaiters.forEach { $0.resume() }
        return operation
    }
}

@MainActor
final class LiveSceneCoordinator: NSObject, ObservableObject {
    @Published private(set) var programPreviewFrame = LiveProgramPreviewFrame()
    @Published private(set) var selectedCameraID: String?
    @Published private(set) var cameraSession: AVCaptureSession?
    @Published private(set) var cameraImage: NSImage?
    @Published private(set) var isCameraFrameReady = false
    @Published private(set) var screenPreviewError: String?
    @Published private(set) var sourceHealth = LiveSourceHealthSnapshot.empty

    var screenImage: NSImage? { programPreviewFrame.image }
    var programPresentation: CapturePresentationSnapshot? { programPreviewFrame.presentation }

    private let screenQueue = DispatchQueue(label: "StudioRecorder.preview.screen", qos: .userInitiated)
    private let cameraQueue = DispatchQueue(label: "StudioRecorder.preview.camera", qos: .userInitiated)
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let cameraBackgroundProcessor = CameraBackgroundProcessor(personQuality: .live)
    private let snapshotExporter = LiveSceneSnapshotExporter()
    nonisolated(unsafe) private var isFrameDeliveryPending = false
    nonisolated private let frameDeliveryLock = NSLock()
    nonisolated(unsafe) private var isCameraFrameDeliveryPending = false
    nonisolated(unsafe) private var lastCameraFrameProcessingTime: TimeInterval = 0
    nonisolated private let cameraFrameDeliveryLock = NSLock()
    nonisolated(unsafe) private var cameraBackground = CameraBackgroundSnapshot.off
    nonisolated private let cameraBackgroundLock = NSLock()
    nonisolated(unsafe) private var cameraFrameState = CameraFrameState()
    nonisolated private let cameraFrameStateLock = NSLock()
    nonisolated(unsafe) private var streamPipeline: LiveProgramPipeline?
    nonisolated private let streamPipelineLock = NSLock()
    nonisolated(unsafe) private var sceneSwitchResolver: StudioSceneSwitchResolver?
    nonisolated private let sceneSwitchResolverLock = NSLock()
    nonisolated private let screenPipelineIngress = LatestAsyncTaskQueue()
    nonisolated private let sourceHealthMonitor = LiveSourceHealthMonitor()
    nonisolated(unsafe) private var screenHealthSourceByStreamID: [ObjectIdentifier: LiveSourceID] = [:]
    nonisolated private let screenHealthSourceLock = NSLock()
    nonisolated private let streamCursorSynchronizer = CursorFrameSynchronizer(
        contentLatencySystemUnits: CursorFrameSynchronizer.screenContentLatencySystemUnits
    )
    private var streamAudioConfiguration: LiveStreamAudioConfiguration?
    private var cursorTelemetryTask: Task<Void, Never>?
    private var sourceHealthTask: Task<Void, Never>?
    private var expectedHealthSources: Set<LiveSourceID> = []
    private var screenStream: SCStream?
    private var previewedDisplay: SCDisplay?
    private var previewedDisplayID: UInt32?
    private var cameraInput: AVCaptureDeviceInput?
    private var cameraVideoOutput: AVCaptureVideoDataOutput?

    func startScreenPreview(
        for displayID: UInt32,
        preservingLastFrame: Bool = false
    ) async {
        guard previewedDisplayID != displayID || screenStream == nil else { return }
        await stopScreenPreview(preservingLastFrame: preservingLastFrame)
        screenPreviewError = nil

        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                screenPreviewError = "The selected display is no longer available."
                return
            }
            let ownApplication = content.applications.first { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: ownApplication.map { [$0] } ?? [],
                exceptingWindows: []
            )
            let configuration = SCStreamConfiguration()
            let previewScale = min(
                1,
                1_920 / CGFloat(display.width),
                1_080 / CGFloat(display.height)
            )
            configuration.width = max(640, Int(CGFloat(display.width) * previewScale))
            configuration.height = max(360, Int(CGFloat(display.height) * previewScale))
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.queueDepth = 3
            configuration.showsCursor = streamPipelineLock.withLock { streamPipeline == nil }
            if let streamAudioConfiguration {
                configuration.capturesAudio = streamAudioConfiguration.capturesSystemAudio
                configuration.captureMicrophone = streamAudioConfiguration.capturesMicrophone
                configuration.microphoneCaptureDeviceID = streamAudioConfiguration.capturesMicrophone
                    ? streamAudioConfiguration.microphoneDeviceID
                    : nil
                configuration.excludesCurrentProcessAudio = streamAudioConfiguration.excludesStudioRecorderAudio
            } else {
                configuration.capturesAudio = false
                configuration.captureMicrophone = false
            }
            configuration.streamName = "Studio preview (\(display.displayID))"

            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
            if streamAudioConfiguration?.capturesSystemAudio == true {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: screenQueue)
            }
            if streamAudioConfiguration?.capturesMicrophone == true {
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: screenQueue)
            }
            streamCursorSynchronizer.reset()
            streamCursorSynchronizer.register(
                streamID: ObjectIdentifier(stream),
                space: CursorCaptureSpace(displayID: display.displayID, visibleFrame: display.frame)
            )
            screenHealthSourceLock.withLock {
                screenHealthSourceByStreamID[ObjectIdentifier(stream)] = .screen(displayID: display.displayID)
            }
            startCursorTelemetry()
            try await stream.startCapture()
            screenStream = stream
            previewedDisplay = display
            previewedDisplayID = displayID
        } catch {
            cursorTelemetryTask?.cancel()
            cursorTelemetryTask = nil
            streamCursorSynchronizer.reset()
            screenPreviewError = error.localizedDescription
        }
    }

    func stopScreenPreview(preservingLastFrame: Bool = false) async {
        let stream = screenStream
        if let stream {
            screenHealthSourceLock.withLock {
                screenHealthSourceByStreamID[ObjectIdentifier(stream)] = nil
            }
        }
        screenStream = nil
        previewedDisplay = nil
        previewedDisplayID = nil
        if !preservingLastFrame {
            programPreviewFrame.image = nil
        }
        cursorTelemetryTask?.cancel()
        cursorTelemetryTask = nil
        streamCursorSynchronizer.reset()
        guard let stream else { return }
        try? await stream.stopCapture()
    }

    func selectCamera(_ id: String?) {
        selectedCameraID = id
    }

    func startCameraPreview() {
        configureCameraPreview()
    }

    func setCameraBackground(_ background: CameraBackgroundSnapshot) {
        let validated = background.validated()
        let changed = cameraBackgroundLock.withLock { () -> Bool in
            guard cameraBackground != validated else { return false }
            cameraBackground = validated
            return true
        }
        if changed { cameraImage = nil }
    }

    func setStreamPipeline(
        _ pipeline: LiveProgramPipeline?,
        audio: LiveStreamAudioConfiguration?
    ) async {
        streamPipelineLock.withLock { streamPipeline = pipeline }
        guard streamAudioConfiguration != audio else { return }
        streamAudioConfiguration = audio
        guard let displayID = previewedDisplayID else { return }
        await stopScreenPreview(preservingLastFrame: true)
        await startScreenPreview(for: displayID, preservingLastFrame: true)
    }

    func monitorSourceHealth(_ expectedSources: Set<LiveSourceID>) {
        guard expectedHealthSources != expectedSources else { return }
        expectedHealthSources = expectedSources
        sourceHealthTask?.cancel()
        sourceHealthTask = nil
        sourceHealthMonitor.configure(
            expected: expectedSources,
            at: ProcessInfo.processInfo.systemUptime
        )
        sourceHealth = sourceHealthMonitor.snapshot(at: ProcessInfo.processInfo.systemUptime)
        guard !expectedSources.isEmpty else { return }
        sourceHealthTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                self.sourceHealth = self.sourceHealthMonitor.snapshot(
                    at: ProcessInfo.processInfo.systemUptime
                )
            }
        }
    }

    func beginProgramPresentation(_ presentation: CapturePresentationSnapshot) {
        let validated = presentation.validated()
        sceneSwitchResolverLock.withLock {
            sceneSwitchResolver = StudioSceneSwitchResolver(initialPresentation: validated)
        }
        programPreviewFrame.presentation = validated
    }

    func enqueueSceneSwitch(
        _ event: StudioSceneSwitchEvent,
        currentPresentation: CapturePresentationSnapshot
    ) {
        let initial = (programPresentation ?? currentPresentation).validated()
        sceneSwitchResolverLock.withLock {
            if sceneSwitchResolver == nil {
                sceneSwitchResolver = StudioSceneSwitchResolver(initialPresentation: initial)
            }
            sceneSwitchResolver?.schedule(event)
        }
        if programPresentation == nil { programPreviewFrame.presentation = initial }
    }

    func replaceProgramPresentationImmediately(_ presentation: CapturePresentationSnapshot) {
        let validated = presentation.validated()
        sceneSwitchResolverLock.withLock {
            if sceneSwitchResolver == nil {
                sceneSwitchResolver = StudioSceneSwitchResolver(initialPresentation: validated)
            } else {
                sceneSwitchResolver?.replaceImmediately(with: validated)
            }
        }
        programPreviewFrame.presentation = validated
    }

    func endProgramPresentation() {
        sceneSwitchResolverLock.withLock { sceneSwitchResolver = nil }
        programPreviewFrame.presentation = nil
    }

    func stopCameraPreview() async {
        let session = cameraSession
        cameraSession = nil
        cameraInput = nil
        cameraVideoOutput = nil
        cameraImage = nil
        setActiveCameraOutput(nil)
        guard let session else { return }
        await withCheckedContinuation { continuation in
            cameraQueue.async {
                session.stopRunning()
                continuation.resume()
            }
        }
    }

    func saveProgramSnapshot(
        presentation: CapturePresentationSnapshot,
        capturesCamera: Bool,
        includesCursor: Bool,
        excludesStudioRecorder: Bool,
        shortcutLabel: String? = nil,
        to destinationURL: URL
    ) async throws {
        guard let previewedDisplay else {
            throw LiveSceneSnapshotCaptureError.screenUnavailable
        }
        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == previewedDisplay.displayID }) else {
            throw LiveSceneSnapshotCaptureError.screenUnavailable
        }
        let ownApplication = content.applications.first {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludesStudioRecorder ? (ownApplication.map { [$0] } ?? []) : [],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = false
        configuration.capturesAudio = false
        let screen = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        let camera = try LiveSceneSnapshotCaptureError.cameraFrame(
            capturesCamera: capturesCamera,
            cameraIsVisible: presentation.camera.isVisible,
            availableFrame: cameraFrameStateLock.withLock { cameraFrameState.pixelBuffer }
        )
        let cursor = includesCursor ? contentAlignedCursor(on: display) : nil
        let framing = effectiveSnapshotFraming(
            presentation: presentation,
            cursor: cursor
        )
        try await snapshotExporter.export(
            sources: LiveSceneSnapshotSources(screen: screen, camera: camera),
            presentation: presentation,
            screenFraming: framing,
            cursor: cursor,
            shortcutLabel: shortcutLabel,
            to: destinationURL
        )
    }

    private func contentAlignedCursor(on display: SCDisplay) -> ProgramCursorState? {
        let hostTime = CMClockConvertHostTimeToSystemUnits(CMClockGetTime(CMClockGetHostTimeClock()))
        let hostSample = streamCursorSynchronizer.sample(forFrameAt: hostTime) ?? CursorHostSample(
            hostTime: hostTime,
            location: CGEvent(source: nil)?.location ?? .zero,
            isPrimaryButtonDown: CGEventSource.buttonState(.combinedSessionState, button: .left)
        )
        let location = hostSample.location
        let frame = display.frame
        guard frame.width > 0, frame.height > 0, frame.contains(location) else { return nil }
        return ProgramCursorState(
            normalizedX: (location.x - frame.minX) / frame.width,
            normalizedY: (location.y - frame.minY) / frame.height,
            isPrimaryButtonDown: hostSample.isPrimaryButtonDown
        )
    }

    private func effectiveSnapshotFraming(
        presentation: CapturePresentationSnapshot,
        cursor: ProgramCursorState?
    ) -> ScreenFramingSnapshot? {
        switch presentation.framing.mode {
        case .fullDisplay:
            nil
        case .fixedRegion:
            presentation.framing
        case .followCursor:
            ScreenFramingSnapshot(
                mode: .fixedRegion,
                centerX: cursor?.normalizedX ?? presentation.framing.centerX,
                centerY: cursor?.normalizedY ?? presentation.framing.centerY,
                scale: presentation.framing.scale
            ).validated()
        }
    }

    private func startCursorTelemetry() {
        cursorTelemetryTask?.cancel()
        recordCursorHostSample()
        cursorTelemetryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.recordCursorHostSample()
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    private func recordCursorHostSample() {
        streamCursorSynchronizer.record(
            CursorHostSample(
                hostTime: CMClockConvertHostTimeToSystemUnits(CMClockGetTime(CMClockGetHostTimeClock())),
                location: CGEvent(source: nil)?.location ?? .zero,
                isPrimaryButtonDown: CGEventSource.buttonState(.combinedSessionState, button: .left)
            )
        )
    }

    private func configureCameraPreview() {
        let previousSession = cameraSession
        guard let selectedCameraID,
              let device = AVCaptureDevice(uniqueID: selectedCameraID) else {
            cameraSession = nil
            cameraInput = nil
            cameraVideoOutput = nil
            cameraImage = nil
            setActiveCameraOutput(nil)
            if let previousSession {
                cameraQueue.async {
                    previousSession.stopRunning()
                }
            }
            return
        }
        if cameraInput?.device.uniqueID == selectedCameraID,
           cameraSession != nil {
            return
        }
        cameraImage = nil
        setActiveCameraOutput(nil)

        let session = AVCaptureSession()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                if let previousSession {
                    cameraQueue.async { previousSession.stopRunning() }
                }
                cameraSession = nil
                cameraInput = nil
                cameraVideoOutput = nil
                cameraImage = nil
                setActiveCameraOutput(nil)
                return
            }
            session.addInput(input)
            let videoOutput = AVCaptureVideoDataOutput()
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            ]
            guard session.canAddOutput(videoOutput) else {
                if let previousSession {
                    cameraQueue.async { previousSession.stopRunning() }
                }
                cameraSession = nil
                cameraInput = nil
                cameraVideoOutput = nil
                cameraImage = nil
                setActiveCameraOutput(nil)
                return
            }
            session.addOutput(videoOutput)
            videoOutput.setSampleBufferDelegate(self, queue: cameraQueue)
            cameraInput = input
            cameraVideoOutput = videoOutput
            cameraSession = session
            setActiveCameraOutput(videoOutput)
            cameraQueue.async {
                previousSession?.stopRunning()
                session.startRunning()
            }
        } catch {
            cameraSession = nil
            cameraInput = nil
            cameraVideoOutput = nil
            cameraImage = nil
            setActiveCameraOutput(nil)
            if let previousSession {
                cameraQueue.async { previousSession.stopRunning() }
            }
        }
    }

    private func setActiveCameraOutput(_ output: AVCaptureVideoDataOutput?) {
        cameraFrameStateLock.withLock {
            cameraFrameState = CameraFrameState(
                outputID: output.map(ObjectIdentifier.init),
                pixelBuffer: nil
            )
        }
        isCameraFrameReady = false
    }

    private func markCameraFrameReady(for outputID: ObjectIdentifier) {
        guard cameraFrameStateLock.withLock({
            cameraFrameState.outputID == outputID && cameraFrameState.pixelBuffer != nil
        }) else { return }
        isCameraFrameReady = true
    }
}

extension LiveSceneCoordinator: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let outputID = ObjectIdentifier(output)
        let acceptedFrame = cameraFrameStateLock.withLock { () -> Bool in
            guard cameraFrameState.outputID == outputID else { return false }
            cameraFrameState.pixelBuffer = pixelBuffer
            return true
        }
        guard acceptedFrame else { return }
        sourceHealthMonitor.record(.camera, at: ProcessInfo.processInfo.systemUptime)
        Task { @MainActor [weak self] in self?.markCameraFrameReady(for: outputID) }
        if let pipeline = streamPipelineLock.withLock({ streamPipeline }) {
            let box = SendableSampleBuffer(value: sampleBuffer)
            Task { await pipeline.appendCamera(box) }
        }
        let background = cameraBackgroundLock.withLock { cameraBackground }
        guard background.mode != .off else { return }
        let shouldDeliver = cameraFrameDeliveryLock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            guard !isCameraFrameDeliveryPending,
                  now - lastCameraFrameProcessingTime >= 1.0 / 30.0 else { return false }
            isCameraFrameDeliveryPending = true
            lastCameraFrameProcessingTime = now
            return true
        }
        guard shouldDeliver else { return }
        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
        let maximumPreviewDimension: CGFloat = 540
        let previewScale = min(
            1,
            maximumPreviewDimension / max(sourceImage.extent.width, sourceImage.extent.height)
        )
        let previewImage = sourceImage.transformed(by: CGAffineTransform(
            scaleX: previewScale,
            y: previewScale
        ))
        let processed = cameraBackgroundProcessor.process(
            previewImage,
            background: background
        )
        guard let cgImage = imageContext.createCGImage(processed, from: processed.extent) else {
            cameraFrameDeliveryLock.withLock { isCameraFrameDeliveryPending = false }
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.cameraImage = NSImage(cgImage: cgImage, size: .zero)
            self.cameraFrameDeliveryLock.withLock { self.isCameraFrameDeliveryPending = false }
        }
    }
}

extension LiveSceneCoordinator: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        let healthSource: LiveSourceID? = switch outputType {
        case .screen: screenHealthSourceLock.withLock {
            screenHealthSourceByStreamID[ObjectIdentifier(stream)]
        }
        case .audio: .systemAudio
        case .microphone: .microphone
        @unknown default: nil
        }
        let screenFrameStatus = outputType == .screen ? frameStatus(in: sampleBuffer) : nil
        let isAcceptedHealthSample = switch outputType {
        case .screen: screenFrameStatus == .complete || screenFrameStatus == .idle
        case .audio, .microphone: true
        @unknown default: false
        }
        if let healthSource,
           isAcceptedHealthSample,
           CMSampleBufferIsValid(sampleBuffer),
           CMSampleBufferDataIsReady(sampleBuffer) {
            sourceHealthMonitor.record(healthSource, at: ProcessInfo.processInfo.systemUptime)
        }
        let displayHostTime = outputType == .screen ? frameDisplayTime(in: sampleBuffer) : nil
        let framePresentation = outputType == .screen
            ? resolveProgramPresentation(forFrameHostTime: displayHostTime)
            : nil
        let pipeline = streamPipelineLock.withLock { streamPipeline }
        if let pipeline {
            let box = SendableSampleBuffer(value: sampleBuffer)
            switch outputType {
            case .screen:
                let cursor = displayHostTime.flatMap { displayTime -> ProgramCursorState? in
                    guard let sample = streamCursorSynchronizer.alignFrame(
                        streamID: ObjectIdentifier(stream),
                        hostTime: displayTime,
                        recordsTimeline: false
                    ) else { return nil }
                    return ProgramCursorState(
                        normalizedX: sample.normalizedX,
                        normalizedY: sample.normalizedY,
                        isPrimaryButtonDown: sample.isPrimaryButtonDown
                    )
                }
                screenPipelineIngress.enqueue {
                    await pipeline.appendScreen(
                        box,
                        cursor: cursor,
                        presentation: framePresentation
                    )
                }
            case .audio:
                Task { await pipeline.appendAudio(box, track: 0) }
            case .microphone:
                Task { await pipeline.appendAudio(box, track: 1) }
            @unknown default:
                break
            }
        }
        guard outputType == .screen,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let shouldDeliver = frameDeliveryLock.withLock {
            guard !isFrameDeliveryPending else { return false }
            isFrameDeliveryPending = true
            return true
        }
        guard shouldDeliver else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = imageContext.createCGImage(image, from: image.extent) else {
            frameDeliveryLock.withLock { isFrameDeliveryPending = false }
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.programPreviewFrame = LiveProgramPreviewFrame(
                image: NSImage(cgImage: cgImage, size: .zero),
                presentation: framePresentation ?? self.programPreviewFrame.presentation
            )
            self.frameDeliveryLock.withLock { self.isFrameDeliveryPending = false }
        }
    }

    nonisolated private func resolveProgramPresentation(
        forFrameHostTime hostTime: UInt64?
    ) -> CapturePresentationSnapshot? {
        sceneSwitchResolverLock.withLock {
            guard sceneSwitchResolver != nil else { return nil }
            return sceneSwitchResolver?.resolve(forFrameHostTime: hostTime)
        }
    }

    nonisolated private func frameDisplayTime(in sampleBuffer: CMSampleBuffer) -> UInt64? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let frameInfo = attachments.first else { return nil }
        return (frameInfo[.displayTime] as? NSNumber)?.uint64Value
    }

    nonisolated private func frameStatus(in sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let frameInfo = attachments.first,
        let rawValue = (frameInfo[.status] as? NSNumber)?.intValue else { return nil }
        return SCFrameStatus(rawValue: rawValue)
    }
}

struct CameraLivePreview: NSViewRepresentable {
    let session: AVCaptureSession?

    func makeNSView(context: Context) -> CameraPreviewNSView {
        CameraPreviewNSView()
    }

    func updateNSView(_ view: CameraPreviewNSView, context: Context) {
        view.session = session
    }
}

final class CameraPreviewNSView: NSView {
    override var wantsUpdateLayer: Bool { true }

    var session: AVCaptureSession? {
        didSet {
            previewLayer.session = session
        }
    }

    private let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}
