import Foundation

struct TimelapseCaptureContext {
    let presentation: CapturePresentationSnapshot
    let displayID: UInt32?
    let capturesCamera: Bool
    let includesCursor: Bool
    let excludesStudioRecorder: Bool
    let shortcutLabel: String?
}

@MainActor
final class TimelapseCaptureSession {
    private let writer: TimelapseSourceWriter
    private let interval: Duration
    private let frameProvider: @MainActor () async throws -> TimelapseFrame
    private let onFrame: @MainActor (Int) -> Void
    private let onFailure: @MainActor (String) -> Void
    private var samplingTask: Task<Void, Never>?
    private var nextCaptureAt = ContinuousClock.now
    private var generation = 0
    private var isPaused = false
    private var isStopped = false
    private(set) var frameCount = 0

    init(
        outputURL: URL, canvasSize: CGSize, settings: TimelapseSettings,
        codecPolicy: RecordingCodecPolicy = .h264,
        frameProvider: @escaping @MainActor () async throws -> TimelapseFrame,
        onFrame: @escaping @MainActor (Int) -> Void = { _ in },
        onFailure: @escaping @MainActor (String) -> Void = { _ in }
    ) throws {
        writer = try TimelapseSourceWriter(outputURL: outputURL, canvasSize: canvasSize, codecPolicy: codecPolicy)
        interval = .seconds(settings.validated().captureInterval)
        self.frameProvider = frameProvider
        self.onFrame = onFrame
        self.onFailure = onFailure
    }

    func start() async throws {
        try await captureFrame()
        nextCaptureAt = .now.advanced(by: interval)
        samplingTask = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled && !isStopped {
                    try await ContinuousClock().sleep(until: nextCaptureAt)
                    guard ContinuousClock.now >= nextCaptureAt else { continue }
                    nextCaptureAt = nextCaptureAt.advanced(by: interval)
                    if !isPaused { try await captureFrame() }
                    // Missed ticks never trigger a burst of duplicate frames after a stall or sleep.
                    if nextCaptureAt <= .now { nextCaptureAt = .now.advanced(by: interval) }
                }
            } catch is CancellationError {
                return
            } catch {
                onFailure(error.localizedDescription)
            }
        }
    }

    func pause() {
        isPaused = true
        generation += 1
    }

    func resume() {
        isPaused = false
        generation += 1
        nextCaptureAt = .now.advanced(by: interval)
    }

    func stop() async throws -> URL {
        isStopped = true
        generation += 1
        let task = samplingTask
        samplingTask = nil
        task?.cancel()
        await task?.value
        return try await writer.finish()
    }

    private func captureFrame() async throws {
        let acceptedGeneration = generation
        let frame = try await frameProvider()
        guard !isStopped, !isPaused, acceptedGeneration == generation else { return }
        try Task.checkCancellation()
        try await writer.append(frame)
        frameCount += 1
        onFrame(frameCount)
    }
}
