@preconcurrency import ScreenCaptureKit
import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import SwiftUI

struct AvailableDisplay: Identifiable, Equatable {
    let id: UInt32
    let title: String
    let pixelSize: CGSize
}

enum RecordingState: Equatable {
    case preparing
    case ready
    case recording
    case stopping
    case failed(String)

    var label: String {
        switch self {
        case .preparing: "Checking capture access"
        case .ready: "Ready"
        case .recording: "Recording"
        case .stopping: "Finishing files"
        case .failed(let message): message
        }
    }
}

@MainActor
final class RecordingCoordinator: NSObject, ObservableObject {
    @Published private(set) var state: RecordingState = .preparing
    @Published private(set) var availableDisplays: [AvailableDisplay] = []
    @Published private(set) var availableMicrophones: [AvailableMicrophone] = []
    @Published private(set) var availableCameras: [AvailableCamera] = []
    @Published private(set) var activeProject: RecordingProject?
    @Published private(set) var activeCaptureRequest: CaptureRequest?
    @Published private(set) var recordedDuration: TimeInterval = 0
    @Published private(set) var interruptedProjects: [RecordingProjectSnapshot] = []
    @Published private(set) var projects: [RecordingProjectSnapshot] = []
    @Published private(set) var finalizationWarning: String?

    private struct Capture {
        let displayID: UInt32
        let stream: SCStream
        let output: SCRecordingOutput
    }

    private let projectStore = RecordingProjectStore()
    private let retentionFinalizer = RecordingRetentionFinalizer()
    private var captures: [UInt32: Capture] = [:]
    private var cameraRecorder: CameraTrackRecorder?
    private var durationTask: Task<Void, Never>?
    private var cursorTelemetryTask: Task<Void, Never>?
    nonisolated private let cursorSynchronizer = CursorFrameSynchronizer(
        contentLatencySystemUnits: CursorFrameSynchronizer.screenContentLatencySystemUnits
    )
    nonisolated private let cursorTelemetryQueue = DispatchQueue(
        label: "ua.com.rmarinsky.studiorecorder.cursor-frames",
        qos: .userInteractive
    )
    private var startedOutputIDs: Set<ObjectIdentifier> = []
    private var pendingOutputIDs: Set<ObjectIdentifier> = []
    private var outputCompletion: CheckedContinuation<Bool, Never>?
    private var isTearingDown = false
    private var terminalFailure: String?
    private var configuredProjectDirectories: Set<URL> = []

    override init() {
        super.init()
    }

    func refreshDisplays() async {
        state = .preparing
        await refreshProjects()
        do {
            let content = try await SCShareableContent.current
            availableDisplays = content.displays.map {
                AvailableDisplay(
                    id: $0.displayID,
                    title: "Display \($0.displayID)",
                    pixelSize: CGSize(width: $0.width, height: $0.height)
                )
            }
            state = availableDisplays.isEmpty ? .failed("No displays are available to capture.") : .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func refreshMicrophones() {
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
        availableMicrophones = devices.map {
            AvailableMicrophone(
                id: $0.uniqueID,
                name: $0.localizedName,
                isSystemDefault: $0.uniqueID == defaultID
            )
        }
    }

    func refreshCameras() {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices
        availableCameras = devices.map { AvailableCamera(id: $0.uniqueID, name: $0.localizedName) }
    }

    func configureProjectDestination(_ url: URL) {
        configuredProjectDirectories.insert(url.standardizedFileURL)
    }

    func refreshProjects() async {
        let snapshots = await projectStore.discoverProjects(in: Array(configuredProjectDirectories))
        projects = snapshots
        interruptedProjects = snapshots.filter(\.isInterrupted)
    }

    func recoverProject(_ projectID: String) async throws {
        guard let project = interruptedProjects.first(where: { $0.id == projectID }) else {
            throw RecordingRecoveryError.notRecoverable
        }
        try projectStore.recoverReadableTracks(from: project)
        await refreshProjects()
    }

    func moveRecoveryProjectToTrash(_ projectID: String) async throws {
        guard let project = interruptedProjects.first(where: { $0.id == projectID }),
              project.rootURL.pathExtension == "recordingproject" else {
            throw RecordingRecoveryError.notRecoverable
        }
        _ = try FileManager.default.trashItem(at: project.rootURL, resultingItemURL: nil)
        await refreshProjects()
    }

    func startRecording(_ request: CaptureRequest, cameraPreviewSession: CameraSessionReference? = nil) async {
        guard state == .ready else { return }
        state = .preparing
        terminalFailure = nil
        finalizationWarning = nil
        if let destinationURL = request.storage.destinationURL {
            configureProjectDestination(destinationURL)
        }

        do {
            let content = try await SCShareableContent.current
            let displaysByID = Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) })
            let selected = request.displaySources.compactMap { displaysByID[$0.id] }
            guard selected.count == request.displaySources.count, !selected.isEmpty else {
                state = .failed("A selected display is no longer available. Refresh sources before recording.")
                return
            }

            let project = try projectStore.createProject(request: request)
            activeProject = project
            activeCaptureRequest = request
            let ownApplication = content.applications.first { $0.processID == ProcessInfo.processInfo.processIdentifier }
            startCursorTelemetry(request: request)

            for display in selected {
                let isPrimaryAudioDisplay = display.displayID == request.audio.primaryAudioDisplayID
                let filter = SCContentFilter(
                    display: display,
                    excludingApplications: request.profile.excludeStudioRecorder ? (ownApplication.map { [$0] } ?? []) : [],
                    exceptingWindows: []
                )
                let configuration = makeStreamConfiguration(
                    for: display,
                    filter: filter,
                    capturesSystemAudio: isPrimaryAudioDisplay && request.audio.capturesSystemAudio,
                    capturesMicrophone: isPrimaryAudioDisplay && request.audio.capturesMicrophone,
                    microphoneDeviceID: request.audio.microphone?.id,
                    request: request
                )
                guard let outputURL = projectStore.rawTrackURL(for: display.displayID, in: project) else {
                    throw RecordingProjectStoreError.missingTrackDescriptor(displayID: display.displayID)
                }
                let output = try makeRecordingOutput(url: outputURL, codecPolicy: request.profile.codecPolicy)
                let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
                try stream.addRecordingOutput(output)
                if needsCursorTelemetry(request) {
                    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: cursorTelemetryQueue)
                    cursorSynchronizer.register(
                        streamID: ObjectIdentifier(stream),
                        space: cursorCaptureSpace(for: display, request: request)
                    )
                }
                captures[display.displayID] = Capture(displayID: display.displayID, stream: stream, output: output)
            }

            for capture in captures.values {
                try await capture.stream.startCapture()
                startedOutputIDs.insert(ObjectIdentifier(capture.output))
            }
            if let camera = request.camera {
                guard let outputURL = projectStore.rawTrackURL(for: "camera", in: project) else {
                    throw CameraTrackRecorderError.outputUnavailable
                }
                let recorder = CameraTrackRecorder { [weak self] message in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        terminalFailure = terminalFailure ?? message
                        await beginInterruptedTeardown(reason: message)
                    }
                }
                do {
                    try await recorder.start(
                        deviceID: camera.id,
                        outputURL: outputURL,
                        existingSession: cameraPreviewSession
                    )
                } catch {
                    try? projectStore.markFailure(
                        trackID: project.trackID(for: .camera),
                        detail: error.localizedDescription,
                        in: project
                    )
                    throw error
                }
                cameraRecorder = recorder
                try projectStore.markStarted(trackID: project.trackID(for: .camera), in: project)
            }

            recordedDuration = 0
            startDurationTimer()
            state = .recording
        } catch {
            await beginInterruptedTeardown(reason: error.localizedDescription)
        }
    }

    func stopRecording() async {
        guard state == .recording else { return }
        isTearingDown = true
        state = .stopping
        durationTask?.cancel()
        durationTask = nil
        stopCursorTelemetry()
        let stopErrors = await stopCaptures()

        if let reason = terminalFailure ?? stopErrors.first {
            await completeInterruptedTeardown(reason: reason)
            return
        }

        if let activeProject, let activeCaptureRequest {
            do {
                try persistCursorTelemetry(in: activeProject)
                try await retentionFinalizer.finalize(
                    project: activeProject,
                    request: activeCaptureRequest,
                    projectStore: projectStore,
                    cursorTimeline: recordedCursorTimeline
                )
            } catch {
                do {
                    try projectStore.close(activeProject)
                    finalizationWarning = "The program movie could not be finalized, so editable tracks were kept. \(error.localizedDescription)"
                } catch {
                    await completeInterruptedTeardown(reason: error.localizedDescription)
                    return
                }
            }
        }

        clearCaptureState()
        state = .ready
        await refreshProjects()
        isTearingDown = false
    }

    private func makeStreamConfiguration(
        for display: SCDisplay,
        filter: SCContentFilter,
        capturesSystemAudio: Bool,
        capturesMicrophone: Bool,
        microphoneDeviceID: String?,
        request: CaptureRequest
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let geometry = CaptureGeometryPlanner.streamGeometry(
            displaySize: CGSize(width: display.width, height: display.height),
            pointPixelScale: CGFloat(filter.pointPixelScale),
            presentation: request.presentation
        )
        configuration.width = Int(geometry.outputSize.width.rounded())
        configuration.height = Int(geometry.outputSize.height.rounded())
        if !geometry.sourceRect.isEmpty {
            configuration.sourceRect = geometry.sourceRect
        }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(request.profile.frameRate))
        configuration.queueDepth = 5
        let embedsSystemCursor = request.profile.resolvedCursorRendering == .systemEmbedded
        configuration.showsCursor = request.profile.includeCursor && embedsSystemCursor
        configuration.showMouseClicks = request.profile.includeCursor
            && embedsSystemCursor
            && request.presentation.cursor.highlightsClicks
        configuration.capturesAudio = capturesSystemAudio
        configuration.captureMicrophone = capturesMicrophone
        configuration.microphoneCaptureDeviceID = capturesMicrophone ? microphoneDeviceID : nil
        configuration.excludesCurrentProcessAudio = request.audio.excludesStudioRecorderAudio
        configuration.streamName = "Raw screen \(display.displayID)"
        return configuration
    }

    private func makeRecordingOutput(url: URL, codecPolicy: RecordingCodecPolicy) throws -> SCRecordingOutput {
        let configuration = SCRecordingOutputConfiguration()
        configuration.outputURL = url
        configuration.videoCodecType = switch codecPolicy {
        case .automatic:
            configuration.availableVideoCodecTypes.contains(.hevc) ? .hevc : .h264
        case .h264:
            .h264
        }
        configuration.outputFileType = configuration.availableOutputFileTypes.contains(.mov) ? .mov : .mp4
        return SCRecordingOutput(configuration: configuration, delegate: self)
    }

    private func startDurationTimer() {
        durationTask?.cancel()
        durationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.recordedDuration += 1
            }
        }
    }

    private func startCursorTelemetry(request: CaptureRequest) {
        cursorTelemetryTask?.cancel()
        cursorSynchronizer.reset()
        guard needsCursorTelemetry(request) else { return }

        recordCursorHostSample()
        cursorTelemetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                recordCursorHostSample()
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    private func recordCursorHostSample() {
        let location = CGEvent(source: nil)?.location ?? .zero
        cursorSynchronizer.record(
            CursorHostSample(
                hostTime: CMClockConvertHostTimeToSystemUnits(CMClockGetTime(CMClockGetHostTimeClock())),
                location: location,
                isPrimaryButtonDown: CGEventSource.buttonState(.combinedSessionState, button: .left)
            )
        )
    }

    private func needsCursorTelemetry(_ request: CaptureRequest) -> Bool {
        request.presentation.framing.mode == .followCursor
            || (request.profile.includeCursor && request.profile.resolvedCursorRendering == .composited)
    }

    private func cursorCaptureSpace(for display: SCDisplay, request: CaptureRequest) -> CursorCaptureSpace {
        let displayFrame = display.frame
        guard request.presentation.framing.mode == .fixedRegion else {
            return CursorCaptureSpace(displayID: display.displayID, visibleFrame: displayFrame)
        }
        let sourceRect = CaptureGeometryPlanner.sourceRect(
            displaySize: CGSize(width: display.width, height: display.height),
            canvasSize: request.presentation.canvas.pixelSize,
            framing: request.presentation.framing
        )
        guard display.width > 0, display.height > 0, !sourceRect.isEmpty else {
            return CursorCaptureSpace(displayID: display.displayID, visibleFrame: displayFrame)
        }
        return CursorCaptureSpace(
            displayID: display.displayID,
            visibleFrame: CGRect(
                x: displayFrame.minX + (sourceRect.minX / CGFloat(display.width)) * displayFrame.width,
                y: displayFrame.minY + (sourceRect.minY / CGFloat(display.height)) * displayFrame.height,
                width: (sourceRect.width / CGFloat(display.width)) * displayFrame.width,
                height: (sourceRect.height / CGFloat(display.height)) * displayFrame.height
            )
        )
    }

    private func stopCursorTelemetry() {
        cursorTelemetryTask?.cancel()
        cursorTelemetryTask = nil
    }

    private func persistCursorTelemetry(in project: RecordingProject) throws {
        guard let recordedCursorTimeline else { return }
        try projectStore.writeCursorTimeline(recordedCursorTimeline, in: project)
    }

    private var recordedCursorTimeline: CursorSceneTimeline? {
        let samples = cursorSynchronizer.timelineSamples()
        return samples.isEmpty ? nil : CursorSceneTimeline(samples: samples)
    }

    private func stopCaptures() async -> [String] {
        let activeCaptures = Array(captures.values)
        pendingOutputIDs = Set(activeCaptures.map(\.output).map(ObjectIdentifier.init))
            .intersection(startedOutputIDs)
        var errors: [String] = []

        for capture in activeCaptures {
            do {
                try await capture.stream.stopCapture()
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        if let cameraRecorder {
            do {
                try await cameraRecorder.stop()
                if let activeProject {
                    try projectStore.markFinished(trackID: activeProject.trackID(for: .camera), in: activeProject)
                }
            } catch {
                errors.append(error.localizedDescription)
                if let activeProject {
                    try? projectStore.markFailure(
                        trackID: activeProject.trackID(for: .camera),
                        detail: error.localizedDescription,
                        in: activeProject
                    )
                }
            }
        }
        if await waitForPendingOutputs() {
            errors.append("Timed out while finalizing one or more recording outputs.")
        }
        return errors
    }

    private func capture(for output: SCRecordingOutput) -> Capture? {
        captures.values.first { $0.output === output }
    }

    private func waitForPendingOutputs() async -> Bool {
        guard !pendingOutputIDs.isEmpty else { return false }

        return await withCheckedContinuation { continuation in
            outputCompletion = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.timeOutPendingOutputs()
            }
        }
    }

    private func finishOutput(_ output: SCRecordingOutput) {
        let outputID = ObjectIdentifier(output)
        startedOutputIDs.remove(outputID)
        pendingOutputIDs.remove(outputID)
        if pendingOutputIDs.isEmpty {
            outputCompletion?.resume(returning: false)
            outputCompletion = nil
        }
    }

    private func timeOutPendingOutputs() {
        guard !pendingOutputIDs.isEmpty else { return }
        pendingOutputIDs.removeAll()
        outputCompletion?.resume(returning: true)
        outputCompletion = nil
    }

    private func beginInterruptedTeardown(reason: String) async {
        terminalFailure = terminalFailure ?? reason
        guard !isTearingDown else { return }
        isTearingDown = true
        state = .stopping
        durationTask?.cancel()
        durationTask = nil
        stopCursorTelemetry()
        _ = await stopCaptures()
        await completeInterruptedTeardown(reason: terminalFailure ?? reason)
    }

    private func completeInterruptedTeardown(reason: String) async {
        if let activeProject {
            try? persistCursorTelemetry(in: activeProject)
            try? projectStore.markInterrupted(activeProject, detail: reason)
        }
        clearCaptureState()
        await refreshProjects()
        state = .failed(reason)
        isTearingDown = false
    }

    private func clearCaptureState() {
        stopCursorTelemetry()
        cursorSynchronizer.reset()
        captures.removeAll()
        cameraRecorder = nil
        startedOutputIDs.removeAll()
        pendingOutputIDs.removeAll()
        activeProject = nil
        activeCaptureRequest = nil
    }
}

extension RecordingCoordinator: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            guard let self, let capture = self.capture(for: recordingOutput), let project = self.activeProject else { return }
            try? self.projectStore.markStarted(displayID: capture.displayID, in: project)
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            guard let self, let capture = self.capture(for: recordingOutput), let project = self.activeProject else { return }
            try? self.projectStore.markFinished(displayID: capture.displayID, in: project)
            self.finishOutput(recordingOutput)
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let displayID = self.capture(for: recordingOutput)?.displayID
            if let project = self.activeProject {
                try? self.projectStore.markFailure(displayID: displayID, detail: error.localizedDescription, in: project)
            }
            self.terminalFailure = self.terminalFailure ?? error.localizedDescription
            self.finishOutput(recordingOutput)
            await self.beginInterruptedTeardown(reason: error.localizedDescription)
        }
    }
}

extension RecordingCoordinator: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                  sampleBuffer,
                  createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let frameInfo = attachments.first,
              let displayTime = (frameInfo[.displayTime] as? NSNumber)?.uint64Value else {
            return
        }
        cursorSynchronizer.alignFrame(
            streamID: ObjectIdentifier(stream),
            hostTime: displayTime
        )
    }
}
