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
        case .ready, .preparing, .recording, .stopping:
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
        case .preparing, .recording, .stopping:
            true
        case .ready, .failed:
            false
        }
    }
}

@MainActor
final class LiveSceneCoordinator: NSObject, ObservableObject {
    @Published private(set) var screenImage: NSImage?
    @Published private(set) var selectedCameraID: String?
    @Published private(set) var cameraSession: AVCaptureSession?
    @Published private(set) var cameraImage: NSImage?
    @Published private(set) var screenPreviewError: String?

    private let screenQueue = DispatchQueue(label: "StudioRecorder.preview.screen", qos: .userInitiated)
    private let cameraQueue = DispatchQueue(label: "StudioRecorder.preview.camera", qos: .userInitiated)
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let cameraBackgroundProcessor = CameraBackgroundProcessor(personQuality: .live)
    nonisolated(unsafe) private var isFrameDeliveryPending = false
    nonisolated private let frameDeliveryLock = NSLock()
    nonisolated(unsafe) private var isCameraFrameDeliveryPending = false
    nonisolated(unsafe) private var lastCameraFrameProcessingTime: TimeInterval = 0
    nonisolated private let cameraFrameDeliveryLock = NSLock()
    nonisolated(unsafe) private var cameraBackground = CameraBackgroundSnapshot.off
    nonisolated private let cameraBackgroundLock = NSLock()
    nonisolated(unsafe) private var streamPipeline: LiveProgramPipeline?
    nonisolated(unsafe) private var streamDisplayFrame: CGRect?
    nonisolated private let streamPipelineLock = NSLock()
    private var streamAudioConfiguration: LiveStreamAudioConfiguration?
    private var screenStream: SCStream?
    private var previewedDisplayID: UInt32?
    private var cameraInput: AVCaptureDeviceInput?
    private var cameraVideoOutput: AVCaptureVideoDataOutput?

    func startScreenPreview(for displayID: UInt32) async {
        guard previewedDisplayID != displayID || screenStream == nil else { return }
        await stopScreenPreview()
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
            try await stream.startCapture()
            screenStream = stream
            previewedDisplayID = displayID
            streamPipelineLock.withLock { streamDisplayFrame = display.frame }
        } catch {
            screenPreviewError = error.localizedDescription
        }
    }

    func stopScreenPreview() async {
        let stream = screenStream
        screenStream = nil
        previewedDisplayID = nil
        screenImage = nil
        streamPipelineLock.withLock { streamDisplayFrame = nil }
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
        await stopScreenPreview()
        await startScreenPreview(for: displayID)
    }

    func stopCameraPreview() async {
        let session = cameraSession
        cameraSession = nil
        cameraInput = nil
        cameraVideoOutput = nil
        cameraImage = nil
        guard let session else { return }
        await withCheckedContinuation { continuation in
            cameraQueue.async {
                session.stopRunning()
                continuation.resume()
            }
        }
    }

    private func configureCameraPreview() {
        let previousSession = cameraSession
        guard let selectedCameraID,
              let device = AVCaptureDevice(uniqueID: selectedCameraID) else {
            cameraSession = nil
            cameraInput = nil
            cameraVideoOutput = nil
            cameraImage = nil
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
                return
            }
            session.addOutput(videoOutput)
            videoOutput.setSampleBufferDelegate(self, queue: cameraQueue)
            cameraInput = input
            cameraVideoOutput = videoOutput
            cameraSession = session
            cameraQueue.async {
                previousSession?.stopRunning()
                session.startRunning()
            }
        } catch {
            cameraSession = nil
            cameraInput = nil
            cameraVideoOutput = nil
            cameraImage = nil
            if let previousSession {
                cameraQueue.async { previousSession.stopRunning() }
            }
        }
    }
}

extension LiveSceneCoordinator: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if let pipeline = streamPipelineLock.withLock({ streamPipeline }) {
            let box = SendableSampleBuffer(value: sampleBuffer)
            Task { await pipeline.appendCamera(box) }
        }
        let background = cameraBackgroundLock.withLock { cameraBackground }
        guard background.mode != .off,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
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
        let pipelineContext = streamPipelineLock.withLock { (streamPipeline, streamDisplayFrame) }
        if let pipeline = pipelineContext.0 {
            let box = SendableSampleBuffer(value: sampleBuffer)
            switch outputType {
            case .screen:
                let cursor = pipelineContext.1.flatMap { frame -> ProgramCursorState? in
                    guard frame.width > 0, frame.height > 0,
                          let location = CGEvent(source: nil)?.location,
                          frame.contains(location) else { return nil }
                    return ProgramCursorState(
                        normalizedX: (location.x - frame.minX) / frame.width,
                        normalizedY: (location.y - frame.minY) / frame.height,
                        isPrimaryButtonDown: CGEventSource.buttonState(.combinedSessionState, button: .left)
                    )
                }
                Task { await pipeline.appendScreen(box, cursor: cursor) }
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
            self.screenImage = NSImage(cgImage: cgImage, size: .zero)
            self.frameDeliveryLock.withLock { self.isFrameDeliveryPending = false }
        }
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
