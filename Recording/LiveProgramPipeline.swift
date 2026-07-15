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
        audioConfiguration: LiveStreamAudioConfiguration
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
                    audioConfiguration: audioConfiguration
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
    private var latestCamera: SendableSampleBuffer?
    private var pixelBufferPool: CVPixelBufferPool?
    private var isRunning = false
    private var isTransportLive = false
    private var streamGeneration = 0
    private var activeConfiguration: YouTubeStreamConfiguration?
    private var activeAudioConfiguration: LiveStreamAudioConfiguration?
    private var activeStateHandler: StateHandler?
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

    func start(
        configuration: YouTubeStreamConfiguration,
        presentation: CapturePresentationSnapshot,
        includesCursor: Bool = true,
        audioConfiguration: LiveStreamAudioConfiguration,
        stateHandler: @escaping StateHandler
    ) async throws {
        guard !isRunning else { return }
        streamGeneration += 1
        let generation = streamGeneration
        self.presentation = presentation.validated()
        rendersCursor = includesCursor
        activeConfiguration = configuration
        activeAudioConfiguration = audioConfiguration
        activeStateHandler = stateHandler
        isTransportLive = false
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
                await stateHandler(.live)
            }
        } catch {
            isRunning = false
            isTransportLive = false
            latestCamera = nil
            pixelBufferPool = nil
            activeConfiguration = nil
            activeAudioConfiguration = nil
            activeStateHandler = nil
            await sink.disconnect()
            throw error
        }
    }

    func stop() async {
        guard isRunning else { return }
        streamGeneration += 1
        isRunning = false
        isTransportLive = false
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectRequestedWhileRetrying = false
        latestCamera = nil
        pixelBufferPool = nil
        activeConfiguration = nil
        activeAudioConfiguration = nil
        activeStateHandler = nil
        await sink.disconnect()
    }

    func updatePresentation(_ presentation: CapturePresentationSnapshot) {
        self.presentation = presentation.validated()
    }

    func appendCamera(_ sampleBuffer: SendableSampleBuffer) {
        latestCamera = sampleBuffer
    }

    func appendScreen(
        _ sampleBuffer: SendableSampleBuffer,
        cursor: ProgramCursorState?
    ) async {
        guard isRunning else { return }
        let renderStartedAt = ProcessInfo.processInfo.systemUptime
        healthStartedAt = healthStartedAt ?? renderStartedAt
        guard isTransportLive else {
            droppedVideoFrames += 1
            return
        }
        guard let sourceBuffer = sampleBuffer.value.imageBuffer,
              let outputBuffer = makePixelBuffer() else {
            droppedVideoFrames += 1
            return
        }
        let cameraBuffer = latestCamera?.value.imageBuffer
        compositor.render(
            screen: CIImage(cvPixelBuffer: sourceBuffer),
            camera: cameraBuffer.map(CIImage.init(cvPixelBuffer:)),
            presentation: presentation,
            screenFraming: streamFraming(cursorPosition: cursor.map {
                CGPoint(x: $0.normalizedX, y: $0.normalizedY)
            }),
            cursor: rendersCursor ? cursor : nil,
            to: outputBuffer
        )
        guard let composed = makeSampleBuffer(
            pixelBuffer: outputBuffer,
            timingSource: sampleBuffer.value
        ) else {
            droppedVideoFrames += 1
            return
        }
        await sink.appendVideo(SendableSampleBuffer(value: composed))
        composedVideoFrames += 1
        totalRenderDuration += ProcessInfo.processInfo.systemUptime - renderStartedAt
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
        guard isRunning, isTransportLive else { return }
        await sink.appendAudio(sampleBuffer, track: track)
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
                await stateHandler(.live)
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
        latestCamera = nil
        pixelBufferPool = nil
        activeConfiguration = nil
        activeAudioConfiguration = nil
        activeStateHandler = nil
        reconnectTask = nil
        reconnectRequestedWhileRetrying = false
        let detail = lastError?.localizedDescription ?? "The connection did not recover."
        await stateHandler(.failed(
            "YouTube reconnect failed after \(reconnectPolicy.maximumAttempts) attempts. \(detail)"
        ))
    }

    private func streamFraming(cursorPosition: CGPoint?) -> ScreenFramingSnapshot? {
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
}
