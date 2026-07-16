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
    case paused
    case stopping
    case failed(String)

    var label: String {
        switch self {
        case .preparing: "Checking capture access"
        case .ready: "Ready"
        case .recording: "Recording"
        case .paused: "Recording paused"
        case .stopping: "Finishing files"
        case .failed(let message): message
        }
    }
}

private final class RecordingAudioStemSessionState: @unchecked Sendable {
    struct Snapshot {
        let writer: RecordingAudioStemWriter?
        let failureDetail: String?
    }

    private struct Session {
        let projectID: UUID
        var writer: RecordingAudioStemWriter?
        var streamID: ObjectIdentifier?
        var failureDetail: String?
    }

    private let lock = NSLock()
    private var session: Session?

    func install(_ writer: RecordingAudioStemWriter, projectID: UUID) {
        let previous = lock.withLock { () -> RecordingAudioStemWriter? in
            let previous = session?.writer
            session = Session(projectID: projectID, writer: writer)
            return previous
        }
        previous?.abort()
    }

    func bind(streamID: ObjectIdentifier, projectID: UUID) {
        lock.withLock {
            guard session?.projectID == projectID else { return }
            session?.streamID = streamID
        }
    }

    func hasWriter(projectID: UUID) -> Bool {
        lock.withLock { session?.projectID == projectID && session?.writer != nil }
    }

    func writer(for streamID: ObjectIdentifier) -> RecordingAudioStemWriter? {
        lock.withLock {
            guard session?.streamID == streamID else { return nil }
            return session?.writer
        }
    }

    func fail(streamID: ObjectIdentifier, detail: String) -> UUID? {
        let result = lock.withLock { () -> (UUID, RecordingAudioStemWriter)? in
            guard var current = session,
                  current.streamID == streamID,
                  current.failureDetail == nil,
                  let writer = current.writer else { return nil }
            current.failureDetail = detail
            current.writer = nil
            current.streamID = nil
            session = current
            return (current.projectID, writer)
        }
        result?.1.abort()
        return result?.0
    }

    func detach(projectID: UUID) -> Snapshot? {
        lock.withLock {
            guard let current = session,
                  current.projectID == projectID else { return nil }
            session = nil
            return Snapshot(writer: current.writer, failureDetail: current.failureDetail)
        }
    }

    func abortAndClear() {
        let writer = lock.withLock { () -> RecordingAudioStemWriter? in
            defer { session = nil }
            return session?.writer
        }
        writer?.abort()
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
    @Published private(set) var sourceHealth = LiveSourceHealthSnapshot.empty

    private struct Capture {
        let displayID: UInt32
        let stream: SCStream
        let output: SCRecordingOutput
    }

    private let projectStore = RecordingProjectStore()
    private let projectEditStore = ProjectEditStore()
    private let retentionFinalizer = RecordingRetentionFinalizer()
    private var captures: [UInt32: Capture] = [:]
    private var cameraRecorder: CameraTrackRecorder?
    nonisolated private let audioStemSession = RecordingAudioStemSessionState()
    private var audioStemFailureReported = false
    private var durationTask: Task<Void, Never>?
    private var sourceHealthTask: Task<Void, Never>?
    private var cursorTelemetryTask: Task<Void, Never>?
    private var studioSceneTimeline: StudioSceneTimeline?
    private var safeShortcutTimeline = SafeShortcutTimeline()
    private var recordingPauseTimeline = RecordingPauseTimeline()
    private var recordingStartedAt: TimeInterval?
    private var recordingStartedHostTime: UInt64?
    private var recordingStartedAtByDisplayID: [UInt32: TimeInterval] = [:]
    private var acceptedSceneSwitchIDs: Set<UUID> = []
    private var hasAuthoritativeRecordingStart = false
    nonisolated private let cursorSynchronizer = CursorFrameSynchronizer(
        contentLatencySystemUnits: CursorFrameSynchronizer.screenContentLatencySystemUnits
    )
    nonisolated private let sourceHealthMonitor = LiveSourceHealthMonitor()
    nonisolated(unsafe) private var healthSourceByStreamID: [ObjectIdentifier: LiveSourceID] = [:]
    nonisolated private let healthSourceLock = NSLock()
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
    private var lastCameraHealthDuration: TimeInterval = 0

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
        try await projectStore.restorePauseEdits(from: project)
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
        recordingStartedAt = nil
        recordingStartedHostTime = nil
        recordingStartedAtByDisplayID = [:]
        acceptedSceneSwitchIDs = []
        audioStemSession.abortAndClear()
        audioStemFailureReported = false
        hasAuthoritativeRecordingStart = false
        recordingPauseTimeline = RecordingPauseTimeline()
        safeShortcutTimeline = SafeShortcutTimeline()
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
            var expectedSources = Set(selected.map { LiveSourceID.screen(displayID: $0.displayID) })
            if request.camera != nil { expectedSources.insert(.camera) }
            if request.audio.capturesSystemAudio { expectedSources.insert(.systemAudio) }
            if request.audio.capturesMicrophone { expectedSources.insert(.microphone) }
            sourceHealthMonitor.configure(
                expected: expectedSources,
                at: ProcessInfo.processInfo.systemUptime
            )
            sourceHealth = sourceHealthMonitor.snapshot(at: ProcessInfo.processInfo.systemUptime)
            lastCameraHealthDuration = 0

            let project = try projectStore.createProject(request: request)
            activeProject = project
            activeCaptureRequest = request
            if let trackID = project.trackID(for: .audio),
               let outputURL = projectStore.rawTrackURL(for: trackID, in: project) {
                let writer = try RecordingAudioStemWriter(configuration: .init(
                    outputURL: outputURL,
                    capturesSystemAudio: request.audio.capturesSystemAudio,
                    capturesMicrophone: request.audio.capturesMicrophone
                ))
                audioStemSession.install(writer, projectID: project.id)
            }
            studioSceneTimeline = StudioSceneTimeline(initialPresentation: request.presentation)
            if let studioSceneTimeline {
                try projectStore.writeStudioSceneTimeline(studioSceneTimeline, in: project)
            }
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
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: cursorTelemetryQueue)
                healthSourceLock.withLock {
                    healthSourceByStreamID[ObjectIdentifier(stream)] = .screen(displayID: display.displayID)
                }
                let capturesAudioStems = isPrimaryAudioDisplay
                    && audioStemSession.hasWriter(projectID: project.id)
                if capturesAudioStems {
                    audioStemSession.bind(streamID: ObjectIdentifier(stream), projectID: project.id)
                }
                if capturesAudioStems && request.audio.capturesSystemAudio {
                    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: cursorTelemetryQueue)
                }
                if capturesAudioStems && request.audio.capturesMicrophone {
                    try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: cursorTelemetryQueue)
                }
                if needsCursorTelemetry(request) {
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
            if recordingStartedAt == nil {
                recordingStartedAt = ProcessInfo.processInfo.systemUptime
                recordingStartedHostTime = Self.currentHostTime
            }
            startDurationTimer()
            startSourceHealthTimer()
            state = .recording
        } catch {
            await beginInterruptedTeardown(reason: error.localizedDescription)
        }
    }

    func pauseRecording() {
        guard state == .recording else { return }
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard recordingPauseTimeline.pause(at: timestamp) else { return }
        if let activeProject {
            do {
                try projectStore.markRecordingPaused(in: activeProject)
            } catch {
                finalizationWarning = "Pause is active, but its recovery marker could not be saved. \(error.localizedDescription)"
            }
        }
        durationTask?.cancel()
        durationTask = nil
        if let recordingStartedAt {
            recordedDuration = recordingPauseTimeline.recordedDuration(
                recordingStartedAt: recordingStartedAt,
                at: timestamp
            )
        }
        state = .paused
    }

    func resumeRecording() {
        guard state == .paused else { return }
        guard recordingPauseTimeline.resume(at: ProcessInfo.processInfo.systemUptime) else { return }
        if let activeProject {
            do {
                try projectStore.markRecordingResumed(in: activeProject)
            } catch {
                finalizationWarning = "Recording resumed, but its recovery marker could not be saved. \(error.localizedDescription)"
            }
        }
        startDurationTimer()
        state = .recording
    }

    func recordSafeShortcut(_ label: String) {
        guard state == .recording,
              let recordingStartedAt,
              let activeProject,
              let activeCaptureRequest else { return }
        let sourceTime = max(ProcessInfo.processInfo.systemUptime - recordingStartedAt, 0)
        let presentation = studioSceneTimeline?.presentation(at: sourceTime)
            ?? activeCaptureRequest.presentation
        guard presentation.cursor.resolvedShowsShortcutKeys else { return }
        safeShortcutTimeline.append(label: label, at: sourceTime)
        do {
            try projectStore.writeShortcutTimeline(safeShortcutTimeline, in: activeProject)
        } catch {
            finalizationWarning = "Shortcut display is active, but its editable timing could not be saved. \(error.localizedDescription)"
        }
    }

    func stopRecording() async {
        guard state == .recording || state == .paused else { return }
        isTearingDown = true
        state = .stopping
        durationTask?.cancel()
        durationTask = nil
        stopCursorTelemetry()
        let stopErrors = await stopCaptures()
        let stoppedAt = ProcessInfo.processInfo.systemUptime

        if let reason = terminalFailure ?? stopErrors.first {
            await completeInterruptedTeardown(reason: reason)
            return
        }

        if let activeProject, let activeCaptureRequest {
            do {
                try persistCursorTelemetry(in: activeProject)
                try persistShortcutTelemetry(in: activeProject)
                let pauseEditTimelines = try await makePauseEditTimelines(
                    project: activeProject,
                    request: activeCaptureRequest,
                    stoppedAt: stoppedAt
                )
                if !pauseEditTimelines.isEmpty {
                    try await projectEditStore.save(
                        ProjectEditDocument(
                            projectID: activeProject.id,
                            timelines: pauseEditTimelines,
                            presentation: activeCaptureRequest.presentation
                        ),
                        in: activeProject.rootURL
                    )
                }
                try await retentionFinalizer.finalize(
                    project: activeProject,
                    request: activeCaptureRequest,
                    projectStore: projectStore,
                    cursorTimeline: recordedCursorTimeline,
                    shortcutTimeline: safeShortcutTimeline.events.isEmpty ? nil : safeShortcutTimeline,
                    sceneTimeline: studioSceneTimeline,
                    editTimeline: pauseEditTimelines.first(where: {
                        $0.trackID == preferredScreenTrackID(
                            project: activeProject,
                            request: activeCaptureRequest
                        )
                    })
                )
            } catch {
                do {
                    try projectStore.close(activeProject)
                    finalizationWarning = "The recording is safe, but automatic finalization did not complete. Editable tracks were kept. \(error.localizedDescription)"
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
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                guard let self, let recordingStartedAt else { continue }
                recordedDuration = recordingPauseTimeline.recordedDuration(
                    recordingStartedAt: recordingStartedAt,
                    at: ProcessInfo.processInfo.systemUptime
                )
            }
        }
    }

    private func startSourceHealthTimer() {
        sourceHealthTask?.cancel()
        sourceHealthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if let cameraDuration = await cameraRecorder?.recordedDuration(),
                   cameraDuration > lastCameraHealthDuration + 0.001 {
                    lastCameraHealthDuration = cameraDuration
                    sourceHealthMonitor.record(.camera, at: now)
                }
                sourceHealth = sourceHealthMonitor.snapshot(at: now)
            }
        }
    }

    @discardableResult
    func acceptSceneSwitch(_ event: StudioSceneSwitchEvent) -> Bool {
        guard state == .recording || state == .paused,
              let request = activeCaptureRequest,
              let project = activeProject,
              let recordingStartedHostTime else { return false }
        let contract = StudioSceneLiveContract(
            initialPresentation: request.presentation,
            capturesCamera: request.camera != nil,
            recordsCursorTelemetry: needsCursorTelemetry(request)
        )
        guard contract.incompatibility(for: event.presentation) == nil else { return false }
        if acceptedSceneSwitchIDs.contains(event.id) { return true }
        var timeline = studioSceneTimeline
            ?? StudioSceneTimeline(initialPresentation: request.presentation)
        timeline.append(
            event.presentation,
            at: event.sourceTime(since: recordingStartedHostTime),
            kind: event.kind
        )
        do {
            try projectStore.writeStudioSceneTimeline(timeline, in: project)
        } catch {
            finalizationWarning = "The scene was not switched because its editable timing could not be saved. \(error.localizedDescription)"
            return false
        }
        studioSceneTimeline = timeline
        acceptedSceneSwitchIDs.insert(event.id)
        return true
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

    private func persistShortcutTelemetry(in project: RecordingProject) throws {
        guard !safeShortcutTimeline.events.isEmpty else { return }
        try projectStore.writeShortcutTimeline(safeShortcutTimeline, in: project)
    }

    private func makePauseEditTimelines(
        project: RecordingProject,
        request: CaptureRequest,
        stoppedAt: TimeInterval
    ) async throws -> [ProjectEditTimeline] {
        guard recordingPauseTimeline.hasPauses,
              let recordingStartedAt else { return [] }
        var timelines: [ProjectEditTimeline] = []
        for source in request.displaySources {
            guard let trackID = project.trackID(for: source.id),
                  let trackURL = projectStore.rawTrackURL(for: trackID, in: project) else { continue }
            let duration = try await AVURLAsset(url: trackURL).load(.duration).seconds
            timelines.append(try recordingPauseTimeline.makeEditTimeline(
                trackID: trackID,
                recordingStartedAt: recordingStartedAtByDisplayID[source.id] ?? recordingStartedAt,
                stoppedAt: stoppedAt,
                sourceDuration: duration
            ))
        }
        return timelines
    }

    private func preferredScreenTrackID(project: RecordingProject, request: CaptureRequest) -> String? {
        (request.primaryAudioDisplayID ?? request.displaySources.first?.id).flatMap(project.trackID(for:))
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
        await finishAudioStems()
        if await waitForPendingOutputs() {
            errors.append("Timed out while finalizing one or more recording outputs.")
        }
        return errors
    }

    private func finishAudioStems() async {
        guard let project = activeProject else {
            audioStemSession.abortAndClear()
            return
        }
        guard let session = audioStemSession.detach(projectID: project.id) else { return }
        if let failureDetail = session.failureDetail {
            reportAudioStemFailure(failureDetail, projectID: project.id)
            return
        }
        guard let writer = session.writer,
              let trackID = project.trackID(for: .audio) else {
            session.writer?.abort()
            return
        }
        do {
            let result = try await writer.finish()
            let identities = result.persistentTrackIDs.map { source, trackID in
                ProjectAudioStemTrackIdentity(
                    source: source == .systemAudio ? .systemAudio : .microphone,
                    persistentTrackID: trackID
                )
            }.sorted { $0.source.rawValue < $1.source.rawValue }
            try projectStore.writeAudioStemIndex(ProjectAudioStemIndex(tracks: identities), in: project)
            try projectStore.markStarted(trackID: trackID, in: project)
            try projectStore.markFinished(trackID: trackID, in: project)
        } catch {
            try? projectStore.markFailure(trackID: trackID, detail: error.localizedDescription, in: project)
            finalizationWarning = "The screen recording is safe, but separate audio stems are incomplete. \(error.localizedDescription)"
        }
    }

    private func reportAudioStemFailure(_ detail: String, projectID: UUID) {
        guard !audioStemFailureReported,
              let project = activeProject,
              project.id == projectID else { return }
        audioStemFailureReported = true
        try? projectStore.markFailure(
            trackID: project.trackID(for: .audio),
            detail: detail,
            in: project
        )
        finalizationWarning = "The screen recording continues, but separate audio stems stopped. \(detail)"
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
            try? persistShortcutTelemetry(in: activeProject)
            try? projectStore.markInterrupted(activeProject, detail: reason)
        }
        clearCaptureState()
        await refreshProjects()
        state = .failed(reason)
        isTearingDown = false
    }

    private func clearCaptureState() {
        sourceHealthTask?.cancel()
        sourceHealthTask = nil
        sourceHealthMonitor.configure(expected: [], at: ProcessInfo.processInfo.systemUptime)
        sourceHealth = .empty
        healthSourceLock.withLock { healthSourceByStreamID.removeAll() }
        lastCameraHealthDuration = 0
        stopCursorTelemetry()
        cursorSynchronizer.reset()
        captures.removeAll()
        cameraRecorder = nil
        audioStemSession.abortAndClear()
        audioStemFailureReported = false
        startedOutputIDs.removeAll()
        pendingOutputIDs.removeAll()
        activeProject = nil
        activeCaptureRequest = nil
        studioSceneTimeline = nil
        safeShortcutTimeline = SafeShortcutTimeline()
        recordingStartedAt = nil
        recordingStartedHostTime = nil
        recordingStartedAtByDisplayID = [:]
        acceptedSceneSwitchIDs = []
        hasAuthoritativeRecordingStart = false
        recordingPauseTimeline = RecordingPauseTimeline()
    }

    private func adoptAuthoritativeRecordingStart(
        _ startedAt: TimeInterval,
        hostTime: UInt64,
        in project: RecordingProject
    ) {
        guard !hasAuthoritativeRecordingStart else { return }
        let provisionalStart = recordingStartedAt
        let provisionalHostTime = recordingStartedHostTime
        recordingStartedAt = startedAt
        recordingStartedHostTime = hostTime
        hasAuthoritativeRecordingStart = true

        guard let provisionalStart,
              var timeline = studioSceneTimeline else { return }
        let sceneOffset = provisionalHostTime.map {
            StudioSceneSwitchEvent.hostDuration(from: hostTime, to: $0)
        } ?? (provisionalStart - startedAt)
        timeline.offsetSceneSwitches(by: sceneOffset)
        studioSceneTimeline = timeline
        safeShortcutTimeline.offsetEvents(by: provisionalStart - startedAt)
        do {
            try projectStore.writeStudioSceneTimeline(timeline, in: project)
            try persistShortcutTelemetry(in: project)
        } catch {
            finalizationWarning = "The recording is safe, but scene switch timing could not be updated. \(error.localizedDescription)"
        }
    }

    nonisolated private static var currentHostTime: UInt64 {
        CMClockConvertHostTimeToSystemUnits(CMClockGetTime(CMClockGetHostTimeClock()))
    }
}

extension RecordingCoordinator: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        let outputStartedAt = ProcessInfo.processInfo.systemUptime
        let outputStartedHostTime = Self.currentHostTime
        let outputStartedAtWallClock = Date()
        Task { @MainActor [weak self] in
            guard let self, let capture = self.capture(for: recordingOutput), let project = self.activeProject else { return }
            self.recordingStartedAtByDisplayID[capture.displayID] = outputStartedAt
            let primaryDisplayID = self.activeCaptureRequest?.primaryAudioDisplayID
                ?? self.activeCaptureRequest?.displaySources.first?.id
            if capture.displayID == primaryDisplayID {
                self.adoptAuthoritativeRecordingStart(
                    outputStartedAt,
                    hostTime: outputStartedHostTime,
                    in: project
                )
            }
            try? self.projectStore.markStarted(
                displayID: capture.displayID,
                in: project,
                timestamp: outputStartedAtWallClock
            )
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
        let streamID = ObjectIdentifier(stream)
        do {
            switch outputType {
            case .screen:
                guard CMSampleBufferIsValid(sampleBuffer),
                      CMSampleBufferDataIsReady(sampleBuffer),
                      let attachments = CMSampleBufferGetSampleAttachmentsArray(
                    sampleBuffer,
                    createIfNecessary: false
                ) as? [[SCStreamFrameInfo: Any]],
                let frameInfo = attachments.first,
                let displayTime = (frameInfo[.displayTime] as? NSNumber)?.uint64Value,
                let statusRawValue = (frameInfo[.status] as? NSNumber)?.intValue,
                let status = SCFrameStatus(rawValue: statusRawValue),
                status == .complete || status == .idle else {
                    return
                }
                if let source = healthSourceLock.withLock({ healthSourceByStreamID[streamID] }) {
                    sourceHealthMonitor.record(source, at: ProcessInfo.processInfo.systemUptime)
                }
                if let writer = audioStemSession.writer(for: streamID) {
                    if status == .complete {
                        _ = try writer.establishTimeline(at: sampleBuffer.presentationTimeStamp)
                    }
                }
                cursorSynchronizer.alignFrame(
                    streamID: ObjectIdentifier(stream),
                    hostTime: displayTime
                )
            case .audio:
                guard CMSampleBufferIsValid(sampleBuffer),
                      CMSampleBufferDataIsReady(sampleBuffer),
                      let writer = audioStemSession.writer(for: streamID) else { return }
                try writer.append(sampleBuffer, source: .systemAudio)
                sourceHealthMonitor.record(.systemAudio, at: ProcessInfo.processInfo.systemUptime)
            case .microphone:
                guard CMSampleBufferIsValid(sampleBuffer),
                      CMSampleBufferDataIsReady(sampleBuffer),
                      let writer = audioStemSession.writer(for: streamID) else { return }
                try writer.append(sampleBuffer, source: .microphone)
                sourceHealthMonitor.record(.microphone, at: ProcessInfo.processInfo.systemUptime)
            @unknown default:
                break
            }
        } catch {
            let detail = error.localizedDescription
            guard let projectID = audioStemSession.fail(streamID: streamID, detail: detail) else { return }
            Task { @MainActor [weak self] in
                self?.reportAudioStemFailure(detail, projectID: projectID)
            }
        }
    }
}
