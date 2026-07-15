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

@MainActor
final class YouTubeStreamingCoordinator: ObservableObject {
    @Published private(set) var state: LiveStreamState = .idle

    let pipeline = LiveProgramPipeline()
    private var startTask: Task<Void, Never>?
    private var activeAttemptID: UUID?

    func start(
        configuration: YouTubeStreamConfiguration,
        presentation: CapturePresentationSnapshot,
        audioConfiguration: LiveStreamAudioConfiguration
    ) {
        guard !state.isActive else { return }
        let attemptID = UUID()
        activeAttemptID = attemptID
        state = .connecting
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await pipeline.start(
                    configuration: configuration,
                    presentation: presentation,
                    audioConfiguration: audioConfiguration
                ) { [weak self] state in
                    guard let self, self.activeAttemptID == attemptID else { return }
                    self.state = state
                    if case .failed = state {
                        Task { await self.pipeline.stop() }
                    }
                }
            } catch is CancellationError {
                guard activeAttemptID == attemptID else { return }
                state = .idle
            } catch {
                guard activeAttemptID == attemptID else { return }
                state = .failed(error.localizedDescription)
            }
            if activeAttemptID == attemptID {
                startTask = nil
            }
        }
    }

    func stop() {
        guard state.isActive else { return }
        activeAttemptID = nil
        startTask?.cancel()
        startTask = nil
        state = .stopping
        Task { [weak self] in
            guard let self else { return }
            await pipeline.stop()
            guard activeAttemptID == nil else { return }
            state = .idle
        }
    }
}

actor LiveProgramPipeline {
    typealias StateHandler = @MainActor @Sendable (LiveStreamState) -> Void

    private let sink: any LiveProgramSink
    private let compositor = ProgramFrameCompositor(personQuality: .live)
    private var presentation = CapturePresentationSnapshot.default
    private var latestCamera: SendableSampleBuffer?
    private var pixelBufferPool: CVPixelBufferPool?
    private var isRunning = false

    init(sink: any LiveProgramSink = YouTubeStreamSink()) {
        self.sink = sink
    }

    func start(
        configuration: YouTubeStreamConfiguration,
        presentation: CapturePresentationSnapshot,
        audioConfiguration: LiveStreamAudioConfiguration,
        stateHandler: @escaping StateHandler
    ) async throws {
        guard !isRunning else { return }
        self.presentation = presentation.validated()
        pixelBufferPool = makePixelBufferPool(size: configuration.canvasSize)
        isRunning = true
        do {
            try await sink.connect(
                configuration: configuration,
                audioConfiguration: audioConfiguration,
                stateHandler: stateHandler
            )
        } catch {
            isRunning = false
            latestCamera = nil
            pixelBufferPool = nil
            await sink.disconnect()
            throw error
        }
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        latestCamera = nil
        pixelBufferPool = nil
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
        cursorPosition: CGPoint?
    ) async {
        guard isRunning,
              let sourceBuffer = sampleBuffer.value.imageBuffer,
              let outputBuffer = makePixelBuffer() else { return }
        let cameraBuffer = latestCamera?.value.imageBuffer
        compositor.render(
            screen: CIImage(cvPixelBuffer: sourceBuffer),
            camera: cameraBuffer.map(CIImage.init(cvPixelBuffer:)),
            presentation: presentation,
            screenFraming: streamFraming(cursorPosition: cursorPosition),
            to: outputBuffer
        )
        guard let composed = makeSampleBuffer(
            pixelBuffer: outputBuffer,
            timingSource: sampleBuffer.value
        ) else { return }
        await sink.appendVideo(SendableSampleBuffer(value: composed))
    }

    func appendAudio(_ sampleBuffer: SendableSampleBuffer, track: UInt8) async {
        guard isRunning else { return }
        await sink.appendAudio(sampleBuffer, track: track)
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
