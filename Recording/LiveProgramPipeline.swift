@preconcurrency import AVFoundation
import CoreImage
import CoreVideo
import Foundation

struct LiveStreamAudioConfiguration: Equatable, Sendable {
    let capturesSystemAudio: Bool
    let capturesMicrophone: Bool
    let microphoneDeviceID: String?
    let excludesStudioRecorderAudio: Bool
}

protocol LiveProgramArchiveSink: Sendable {
    func appendVideo(_ sampleBuffer: SendableSampleBuffer) async
    func appendAudio(_ sampleBuffer: SendableSampleBuffer, track: UInt8) async
    func fail(_ message: String) async
    func finish() async
}

struct LiveStreamHealthSnapshot: Equatable, Sendable {
    let canvasSize: CGSize
    let targetFrameRate: Int
    let videoBitRate: Int
    let elapsed: TimeInterval
    let composedVideoFrames: Int
    let droppedVideoFrames: Int
    let averageRenderMilliseconds: Double

    var measuredFrameRate: Double {
        elapsed > 0 ? Double(composedVideoFrames) / elapsed : 0
    }
}

struct LiveStreamReconnectPolicy: Equatable, Sendable {
    let maximumAttempts: Int
    let baseDelaySeconds: TimeInterval
    let maximumDelaySeconds: TimeInterval

    init(
        maximumAttempts: Int = 10,
        baseDelaySeconds: TimeInterval = 1,
        maximumDelaySeconds: TimeInterval = 8
    ) {
        self.maximumAttempts = max(maximumAttempts, 1)
        self.baseDelaySeconds = max(baseDelaySeconds, 0)
        self.maximumDelaySeconds = max(maximumDelaySeconds, 0)
    }

    func delaySeconds(beforeAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0, baseDelaySeconds > 0 else { return 0 }
        return min(baseDelaySeconds * pow(2, Double(attempt - 1)), maximumDelaySeconds)
    }
}

@MainActor
final class YouTubeStreamingCoordinator: ObservableObject {
    @Published private(set) var state: LiveStreamState = .idle
    @Published private(set) var health: LiveStreamHealthSnapshot?

    let pipeline = LiveProgramPipeline()
    private var startTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var activeAttemptID: UUID?

    func start(
        configuration: YouTubeStreamConfiguration,
        presentation: CapturePresentationSnapshot,
        includesCursor: Bool,
        audioConfiguration: LiveStreamAudioConfiguration,
        localArchive: (any LiveProgramArchiveSink)? = nil
    ) {
        guard !state.isActive else { return }
        let attemptID = UUID()
        activeAttemptID = attemptID
        state = .connecting
        beginHealthMonitoring(configuration: configuration, attemptID: attemptID)
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await pipeline.start(
                    configuration: configuration,
                    presentation: presentation,
                    includesCursor: includesCursor,
                    audioConfiguration: audioConfiguration,
                    localArchive: localArchive
                ) { [weak self] state in
                    guard let self, self.activeAttemptID == attemptID else { return }
                    self.state = state
                    if case .failed = state {
                        self.healthTask?.cancel()
                        self.healthTask = nil
                        Task { await self.pipeline.stop() }
                    }
                }
            } catch is CancellationError {
                guard activeAttemptID == attemptID else { return }
                state = .idle
            } catch {
                guard activeAttemptID == attemptID else { return }
                state = .failed(error.localizedDescription)
                healthTask?.cancel()
                healthTask = nil
            }
            if activeAttemptID == attemptID {
                startTask = nil
            }
        }
    }

    func stop() {
        guard state.isActive else { return }
        activeAttemptID = nil
        healthTask?.cancel()
        healthTask = nil
        startTask?.cancel()
        startTask = nil
        state = .stopping
        Task { [weak self] in
            guard let self else { return }
            await pipeline.stop()
            guard activeAttemptID == nil else { return }
            state = .idle
            health = nil
        }
    }

    private func beginHealthMonitoring(configuration: YouTubeStreamConfiguration, attemptID: UUID) {
        healthTask?.cancel()
        health = LiveStreamHealthSnapshot(
            canvasSize: configuration.canvasSize,
            targetFrameRate: configuration.frameRate,
            videoBitRate: configuration.videoBitRate,
            elapsed: 0,
            composedVideoFrames: 0,
            droppedVideoFrames: 0,
            averageRenderMilliseconds: 0
        )
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.activeAttemptID == attemptID else { return }
                self.health = await self.pipeline.healthSnapshot(configuration: configuration)
            }
        }
    }
}

actor LiveProgramPipeline {
    typealias StateHandler = @MainActor @Sendable (LiveStreamState) -> Void

    private let sink: any LiveProgramSink
    private let reconnectPolicy: LiveStreamReconnectPolicy
    private let compositor = ProgramFrameCompositor(personQuality: .live)
    private var presentation = CapturePresentationSnapshot.default
    private var rendersCursor = false
    private var shortcutLabel: String?
    private var shortcutExpiresAt: TimeInterval = 0
    private var latestCamera: SendableSampleBuffer?
    private var pixelBufferPool: CVPixelBufferPool?
    private var isPrepared = false
    private var preparedConfiguration: YouTubeStreamConfiguration?
    private var preparedRequiresCamera = false
    private var isRunning = false
    private var isTransportLive = false
    private var hasSubmittedVideo = false
    private var hasSubmittedAudio = false
    private var hasReportedSending = false
    private var streamGeneration = 0
    private var activeConfiguration: YouTubeStreamConfiguration?
    private var activeAudioConfiguration: LiveStreamAudioConfiguration?
    private var activeStateHandler: StateHandler?
    private var activeArchive: (any LiveProgramArchiveSink)?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectRequestedWhileRetrying = false
    private var healthStartedAt: TimeInterval?
    private var composedVideoFrames = 0
    private var droppedVideoFrames = 0
    private var totalRenderDuration: TimeInterval = 0

    init(
        sink: any LiveProgramSink = YouTubeStreamSink(),
        reconnectPolicy: LiveStreamReconnectPolicy = LiveStreamReconnectPolicy()
    ) {
        self.sink = sink
        self.reconnectPolicy = reconnectPolicy
    }

    func prepare(
        configuration: YouTubeStreamConfiguration,
        presentation: CapturePresentationSnapshot,
        includesCursor: Bool,
        requiresCamera: Bool
    ) {
        guard !isRunning else { return }
        self.presentation = presentation.validated()
        rendersCursor = includesCursor
        latestCamera = nil
        pixelBufferPool = makePixelBufferPool(size: configuration.canvasSize)
        preparedConfiguration = configuration
        preparedRequiresCamera = requiresCamera
        isPrepared = true
    }

    func cancelPreparation() {
        guard !isRunning else { return }
        clearPreparation()
        latestCamera = nil
        pixelBufferPool = nil
    }

    func start(
        configuration: YouTubeStreamConfiguration,
        presentation: CapturePresentationSnapshot,
        includesCursor: Bool = true,
        audioConfiguration: LiveStreamAudioConfiguration,
        localArchive: (any LiveProgramArchiveSink)? = nil,
        stateHandler: @escaping StateHandler
    ) async throws {
        guard !isRunning else { return }
        let validatedPresentation = presentation.validated()
        let canReusePreparation = isPrepared
            && preparedConfiguration == configuration
            && self.presentation == validatedPresentation
        if !canReusePreparation { latestCamera = nil }
        clearPreparation()
        streamGeneration += 1
        let generation = streamGeneration
        self.presentation = validatedPresentation
        rendersCursor = includesCursor
        shortcutLabel = nil
        shortcutExpiresAt = 0
        activeConfiguration = configuration
        activeAudioConfiguration = audioConfiguration
        activeStateHandler = stateHandler
        activeArchive = localArchive
        isTransportLive = false
        resetTransportEvidence()
        pixelBufferPool = makePixelBufferPool(size: configuration.canvasSize)
        healthStartedAt = nil
        composedVideoFrames = 0
        droppedVideoFrames = 0
        totalRenderDuration = 0
        isRunning = true
        do {
            try await connectSink(
                configuration: configuration,
                audioConfiguration: audioConfiguration,
                stateHandler: stateHandler,
                generation: generation,
                reconnectAttempt: nil
            )
            guard isRunning, streamGeneration == generation else {
                await sink.disconnect()
                throw CancellationError()
            }
            if reconnectTask == nil {
                isTransportLive = true
                resetTransportEvidence()
            }
        } catch {
            isRunning = false
            isTransportLive = false
            resetTransportEvidence()
            latestCamera = nil
            clearPreparation()
            pixelBufferPool = nil
            activeConfiguration = nil
            activeAudioConfiguration = nil
            activeStateHandler = nil
            let archive = activeArchive
            activeArchive = nil
            await sink.disconnect()
            await archive?.finish()
            throw error
        }
    }

    func stop() async {
        guard isRunning else { return }
        streamGeneration += 1
        isRunning = false
        isTransportLive = false
        resetTransportEvidence()
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectRequestedWhileRetrying = false
        let archive = activeArchive
        activeArchive = nil
        latestCamera = nil
        clearPreparation()
        shortcutLabel = nil
        shortcutExpiresAt = 0
        pixelBufferPool = nil
        activeConfiguration = nil
        activeAudioConfiguration = nil
        activeStateHandler = nil
        await sink.disconnect()
        await archive?.finish()
    }

    func updatePresentation(_ presentation: CapturePresentationSnapshot) {
        self.presentation = presentation.validated()
        if !self.presentation.cursor.resolvedShowsShortcutKeys {
            shortcutLabel = nil
            shortcutExpiresAt = 0
        }
    }

    func showShortcut(_ label: String, duration: TimeInterval = 1.5) {
        guard presentation.cursor.resolvedShowsShortcutKeys else { return }
        shortcutLabel = String(label.prefix(32))
        shortcutExpiresAt = ProcessInfo.processInfo.systemUptime + min(max(duration, 0.2), 5)
    }

    @discardableResult
    func appendCamera(_ sampleBuffer: SendableSampleBuffer) -> Bool {
        guard isPrepared || isRunning else { return false }
        latestCamera = sampleBuffer
        return true
    }

    @discardableResult
    func appendScreen(
        _ sampleBuffer: SendableSampleBuffer,
        cursor: ProgramCursorState?,
        presentation framePresentation: CapturePresentationSnapshot? = nil
    ) async -> Bool {
        guard isRunning else {
            return renderPreparedScreen(
                sampleBuffer,
                cursor: cursor,
                presentation: framePresentation
            )
        }
        let appliedPresentation = (framePresentation ?? presentation).validated()
        presentation = appliedPresentation
        let renderStartedAt = ProcessInfo.processInfo.systemUptime
        healthStartedAt = healthStartedAt ?? renderStartedAt
        let archive = activeArchive
        guard isTransportLive || archive != nil else {
            droppedVideoFrames += 1
            return false
        }
        guard let sourceBuffer = sampleBuffer.value.imageBuffer,
              let outputBuffer = makePixelBuffer() else {
            droppedVideoFrames += 1
            return false
        }
        let cameraBuffer = latestCamera?.value.imageBuffer
        compositor.render(
            screen: CIImage(cvPixelBuffer: sourceBuffer),
            camera: cameraBuffer.map(CIImage.init(cvPixelBuffer:)),
            presentation: appliedPresentation,
            screenFraming: streamFraming(presentation: appliedPresentation, cursorPosition: cursor.map {
                CGPoint(x: $0.normalizedX, y: $0.normalizedY)
            }),
            cursor: rendersCursor ? cursor : nil,
            shortcutLabel: activeShortcutLabel(for: appliedPresentation),
            to: outputBuffer
        )
        guard let composed = makeSampleBuffer(
            pixelBuffer: outputBuffer,
            timingSource: sampleBuffer.value
        ) else {
            droppedVideoFrames += 1
            return false
        }
        let composedBuffer = SendableSampleBuffer(value: composed)
        if isTransportLive {
            await sink.appendVideo(composedBuffer)
            hasSubmittedVideo = true
            await reportSendingIfReady()
        } else {
            droppedVideoFrames += 1
        }
        if let archive {
            if let archiveBuffer = copySampleBuffer(composed) {
                await archive.appendVideo(archiveBuffer)
            } else {
                activeArchive = nil
                await archive.fail("The composed video buffer could not be copied into the local safety archive.")
            }
        }
        composedVideoFrames += 1
        totalRenderDuration += ProcessInfo.processInfo.systemUptime - renderStartedAt
        return true
    }

    private func renderPreparedScreen(
        _ sampleBuffer: SendableSampleBuffer,
        cursor: ProgramCursorState?,
        presentation framePresentation: CapturePresentationSnapshot?
    ) -> Bool {
        guard isPrepared else { return false }
        let appliedPresentation = (framePresentation ?? presentation).validated()
        guard appliedPresentation == presentation,
              let sourceBuffer = sampleBuffer.value.imageBuffer,
              let outputBuffer = makePixelBuffer() else { return false }
        let cameraBuffer = latestCamera?.value.imageBuffer
        guard !preparedRequiresCamera || cameraBuffer != nil else { return false }
        compositor.render(
            screen: CIImage(cvPixelBuffer: sourceBuffer),
            camera: cameraBuffer.map(CIImage.init(cvPixelBuffer:)),
            presentation: appliedPresentation,
            screenFraming: streamFraming(presentation: appliedPresentation, cursorPosition: cursor.map {
                CGPoint(x: $0.normalizedX, y: $0.normalizedY)
            }),
            cursor: rendersCursor ? cursor : nil,
            shortcutLabel: activeShortcutLabel(for: appliedPresentation),
            to: outputBuffer
        )
        return true
    }

    private func clearPreparation() {
        isPrepared = false
        preparedConfiguration = nil
        preparedRequiresCamera = false
    }

    private func activeShortcutLabel(for presentation: CapturePresentationSnapshot) -> String? {
        guard presentation.cursor.resolvedShowsShortcutKeys,
              ProcessInfo.processInfo.systemUptime < shortcutExpiresAt else { return nil }
        return shortcutLabel
    }

    func healthSnapshot(configuration: YouTubeStreamConfiguration) -> LiveStreamHealthSnapshot {
        let elapsed = healthStartedAt.map { max(ProcessInfo.processInfo.systemUptime - $0, 0) } ?? 0
        return LiveStreamHealthSnapshot(
            canvasSize: configuration.canvasSize,
            targetFrameRate: configuration.frameRate,
            videoBitRate: configuration.videoBitRate,
            elapsed: elapsed,
            composedVideoFrames: composedVideoFrames,
            droppedVideoFrames: droppedVideoFrames,
            averageRenderMilliseconds: composedVideoFrames > 0
                ? totalRenderDuration / Double(composedVideoFrames) * 1_000
                : 0
        )
    }

    func appendAudio(_ sampleBuffer: SendableSampleBuffer, track: UInt8) async {
        guard isRunning else { return }
        if isTransportLive {
            await sink.appendAudio(sampleBuffer, track: track)
            hasSubmittedAudio = true
            await reportSendingIfReady()
        }
        if let archive = activeArchive {
            if let archiveBuffer = copySampleBuffer(sampleBuffer.value) {
                await archive.appendAudio(archiveBuffer, track: track)
            } else {
                activeArchive = nil
                await archive.fail("An audio buffer could not be copied into the local safety archive.")
            }
        }
    }

    private func connectSink(
        configuration: YouTubeStreamConfiguration,
        audioConfiguration: LiveStreamAudioConfiguration,
        stateHandler: @escaping StateHandler,
        generation: Int,
        reconnectAttempt: Int?
    ) async throws {
        try await sink.connect(
            configuration: configuration,
            audioConfiguration: audioConfiguration,
            eventHandler: { [weak self] event in
                await self?.handleSinkEvent(
                    event,
                    stateHandler: stateHandler,
                    generation: generation,
                    reconnectAttempt: reconnectAttempt
                )
            }
        )
    }

    private func handleSinkEvent(
        _ event: LiveProgramSinkEvent,
        stateHandler: @escaping StateHandler,
        generation: Int,
        reconnectAttempt: Int?
    ) async {
        guard isRunning, streamGeneration == generation else { return }
        switch event {
        case .connecting:
            if reconnectAttempt == nil { await stateHandler(.connecting) }
        case .connected:
            break
        case .disconnected:
            beginReconnect(generation: generation)
        case .failed(let message):
            if reconnectAttempt == nil { await stateHandler(.failed(message)) }
        case .idle:
            await stateHandler(.idle)
        case .stopping:
            await stateHandler(.stopping)
        }
    }

    private func beginReconnect(generation: Int) {
        guard isRunning,
              streamGeneration == generation else { return }
        isTransportLive = false
        resetTransportEvidence()
        guard reconnectTask == nil else {
            reconnectRequestedWhileRetrying = true
            return
        }
        reconnectRequestedWhileRetrying = false
        reconnectTask = Task { [weak self] in
            await self?.runReconnectLoop(generation: generation)
        }
    }

    private func runReconnectLoop(generation: Int) async {
        guard let configuration = activeConfiguration,
              let audioConfiguration = activeAudioConfiguration,
              let stateHandler = activeStateHandler else {
            reconnectTask = nil
            return
        }
        var lastError: Error?
        for attempt in 1...reconnectPolicy.maximumAttempts {
            guard isRunning, streamGeneration == generation, !Task.isCancelled else {
                reconnectTask = nil
                return
            }
            reconnectRequestedWhileRetrying = false
            await stateHandler(.reconnecting(
                attempt: attempt,
                maximumAttempts: reconnectPolicy.maximumAttempts
            ))
            do {
                let delay = reconnectPolicy.delaySeconds(beforeAttempt: attempt)
                if delay > 0 {
                    try await Task.sleep(for: .seconds(delay))
                }
                try Task.checkCancellation()
                try await connectSink(
                    configuration: configuration,
                    audioConfiguration: audioConfiguration,
                    stateHandler: stateHandler,
                    generation: generation,
                    reconnectAttempt: attempt
                )
                guard isRunning, streamGeneration == generation, !Task.isCancelled else {
                    await sink.disconnect()
                    reconnectTask = nil
                    return
                }
                if reconnectRequestedWhileRetrying {
                    await sink.disconnect()
                    continue
                }
                isTransportLive = true
                resetTransportEvidence()
                if reconnectRequestedWhileRetrying {
                    isTransportLive = false
                    await sink.disconnect()
                    continue
                }
                reconnectTask = nil
                return
            } catch is CancellationError {
                if Task.isCancelled || !isRunning || streamGeneration != generation {
                    reconnectTask = nil
                    return
                }
                lastError = CancellationError()
                await sink.disconnect()
            } catch {
                lastError = error
                await sink.disconnect()
            }
        }
        guard isRunning, streamGeneration == generation else {
            reconnectTask = nil
            return
        }
        isRunning = false
        isTransportLive = false
        resetTransportEvidence()
        latestCamera = nil
        pixelBufferPool = nil
        activeConfiguration = nil
        activeAudioConfiguration = nil
        activeStateHandler = nil
        let archive = activeArchive
        activeArchive = nil
        reconnectTask = nil
        reconnectRequestedWhileRetrying = false
        let detail = lastError?.localizedDescription ?? "The connection did not recover."
        await archive?.finish()
        await stateHandler(.failed(
            "YouTube reconnect failed after \(reconnectPolicy.maximumAttempts) attempts. \(detail)"
        ))
    }

    private func resetTransportEvidence() {
        hasSubmittedVideo = false
        hasSubmittedAudio = false
        hasReportedSending = false
    }

    private func reportSendingIfReady() async {
        guard isTransportLive,
              !hasReportedSending,
              hasSubmittedVideo,
              let audioConfiguration = activeAudioConfiguration,
              let stateHandler = activeStateHandler else { return }
        let requiresAudio = audioConfiguration.capturesSystemAudio || audioConfiguration.capturesMicrophone
        guard !requiresAudio || hasSubmittedAudio else { return }
        hasReportedSending = true
        await stateHandler(.live)
    }

    private func streamFraming(
        presentation: CapturePresentationSnapshot,
        cursorPosition: CGPoint?
    ) -> ScreenFramingSnapshot? {
        switch presentation.framing.mode {
        case .fullDisplay:
            nil
        case .fixedRegion:
            presentation.framing
        case .followCursor:
            if let cursorPosition {
                ScreenFramingSnapshot(
                    mode: .fixedRegion,
                    centerX: cursorPosition.x,
                    centerY: cursorPosition.y,
                    scale: presentation.framing.scale
                ).validated()
            } else {
                presentation.framing
            }
        }
    }

    private func makePixelBufferPool(size: CGSize) -> CVPixelBufferPool? {
        var pool: CVPixelBufferPool?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else {
            return nil
        }
        return pool
    }

    private func makePixelBuffer() -> CVPixelBuffer? {
        guard let pixelBufferPool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &buffer) == kCVReturnSuccess else {
            return nil
        }
        return buffer
    }

    private func makeSampleBuffer(
        pixelBuffer: CVPixelBuffer,
        timingSource: CMSampleBuffer
    ) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr,
        let formatDescription else { return nil }
        let duration = timingSource.duration.isValid && timingSource.duration.seconds > 0
            ? timingSource.duration
            : CMTime(value: 1, timescale: CMTimeScale(30))
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: timingSource.presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        return sampleBuffer
    }

    private func copySampleBuffer(_ sampleBuffer: CMSampleBuffer) -> SendableSampleBuffer? {
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopy(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleBufferOut: &copy
        ) == noErr,
        let copy else { return nil }
        return SendableSampleBuffer(value: copy)
    }
}
