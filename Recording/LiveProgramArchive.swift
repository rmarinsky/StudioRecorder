@preconcurrency import AVFoundation
import Foundation

enum LiveProgramArchiveState: Equatable, Sendable {
    case idle
    case preparing
    case recording(URL)
    case finalizing(URL)
    case ready(URL)
    case failed(String)

    var label: String {
        switch self {
        case .idle: "Local safety copy ready"
        case .preparing: "Preparing local safety copy"
        case .recording: "Saving local safety copy"
        case .finalizing: "Finalizing local safety copy"
        case .ready: "Local safety copy saved"
        case .failed(let message): "Local safety copy failed: \(message)"
        }
    }

    var isActive: Bool {
        switch self {
        case .preparing, .recording, .finalizing: true
        case .idle, .ready, .failed: false
        }
    }
}

struct LiveProgramMovieWriterConfiguration: Sendable {
    let outputURL: URL
    let canvasSize: CGSize
    let frameRate: Int
    let videoBitRate: Int
    let capturesSystemAudio: Bool
    let capturesMicrophone: Bool
}

enum LiveProgramMovieWriterError: LocalizedError {
    case invalidVideoSettings
    case cannotAddVideoInput
    case cannotAddAudioInput
    case couldNotStart(String)
    case appendFailed(String)
    case backpressure(String)
    case noVideoFrames
    case finishFailed(String)
    case unreadableMovie

    var errorDescription: String? {
        switch self {
        case .invalidVideoSettings:
            "The selected stream dimensions cannot be encoded locally."
        case .cannotAddVideoInput:
            "The local movie could not accept composed video."
        case .cannotAddAudioInput:
            "The local movie could not accept the selected audio sources."
        case .couldNotStart(let detail):
            "The local movie could not start. \(detail)"
        case .appendFailed(let detail):
            "The local movie stopped accepting media. \(detail)"
        case .backpressure(let track):
            "The local encoder could not keep up with \(track); the safety copy was stopped instead of silently dropping media."
        case .noVideoFrames:
            "No composed video frames were received."
        case .finishFailed(let detail):
            "The local movie could not be finalized. \(detail)"
        case .unreadableMovie:
            "The finalized local movie is not playable."
        }
    }
}

protocol LiveProgramMovieWriting: Sendable {
    func appendVideo(_ sampleBuffer: SendableSampleBuffer) async throws
    func appendAudio(_ sampleBuffer: SendableSampleBuffer, track: UInt8) async throws
    func finish() async throws -> URL
    func abort() async
}

actor LiveProgramMovieWriter: LiveProgramMovieWriting {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInputs: [UInt8: AVAssetWriterInput]
    private let outputURL: URL
    private var startedAt: CMTime?
    private var lastVideoTime: CMTime?
    private var lastAudioTimes: [UInt8: CMTime] = [:]
    private var videoFrameCount = 0
    private var isFinished = false

    init(
        configuration: LiveProgramMovieWriterConfiguration,
        fileManager: FileManager = .default
    ) throws {
        outputURL = configuration.outputURL
        try? fileManager.removeItem(at: configuration.outputURL)

        writer = try AVAssetWriter(outputURL: configuration.outputURL, fileType: .mov)
        writer.initialMovieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(configuration.canvasSize.width),
            AVVideoHeightKey: Int(configuration.canvasSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: configuration.videoBitRate,
                AVVideoExpectedSourceFrameRateKey: configuration.frameRate,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw LiveProgramMovieWriterError.invalidVideoSettings
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw LiveProgramMovieWriterError.cannotAddVideoInput
        }
        writer.add(videoInput)
        self.videoInput = videoInput

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        var audioInputs: [UInt8: AVAssetWriterInput] = [:]
        for track in [UInt8(0), UInt8(1)] where
            (track == 0 && configuration.capturesSystemAudio) ||
            (track == 1 && configuration.capturesMicrophone) {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw LiveProgramMovieWriterError.cannotAddAudioInput
            }
            writer.add(input)
            audioInputs[track] = input
        }
        self.audioInputs = audioInputs
    }

    func appendVideo(_ sampleBuffer: SendableSampleBuffer) async throws {
        guard !isFinished else { return }
        let buffer = sampleBuffer.value
        let time = buffer.presentationTimeStamp
        guard isUsable(time), isNewer(time, than: lastVideoTime) else { return }
        if startedAt == nil {
            guard writer.startWriting() else {
                throw LiveProgramMovieWriterError.couldNotStart(
                    writer.error?.localizedDescription ?? "Unknown writer error."
                )
            }
            writer.startSession(atSourceTime: time)
            startedAt = time
        }
        try throwIfWriterFailed()
        guard videoInput.isReadyForMoreMediaData else {
            throw LiveProgramMovieWriterError.backpressure("composed video")
        }
        guard videoInput.append(buffer) else {
            throw LiveProgramMovieWriterError.appendFailed(
                writer.error?.localizedDescription ?? "Video append failed."
            )
        }
        lastVideoTime = time
        videoFrameCount += 1
    }

    func appendAudio(_ sampleBuffer: SendableSampleBuffer, track: UInt8) async throws {
        guard !isFinished,
              let startedAt,
              let input = audioInputs[track] else { return }
        let buffer = sampleBuffer.value
        let time = buffer.presentationTimeStamp
        guard isUsable(time),
              CMTimeCompare(time, startedAt) >= 0,
              isNewer(time, than: lastAudioTimes[track]) else { return }
        try throwIfWriterFailed()
        guard input.isReadyForMoreMediaData else {
            throw LiveProgramMovieWriterError.backpressure(track == 0 ? "system audio" : "microphone audio")
        }
        guard input.append(buffer) else {
            throw LiveProgramMovieWriterError.appendFailed(
                writer.error?.localizedDescription ?? "Audio append failed."
            )
        }
        lastAudioTimes[track] = time
    }

    func finish() async throws -> URL {
        guard !isFinished else { return outputURL }
        isFinished = true
        guard videoFrameCount > 0, startedAt != nil else {
            throw LiveProgramMovieWriterError.noVideoFrames
        }
        videoInput.markAsFinished()
        audioInputs.values.forEach { $0.markAsFinished() }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw LiveProgramMovieWriterError.finishFailed(
                writer.error?.localizedDescription ?? "Unknown writer error."
            )
        }
        let asset = AVURLAsset(url: outputURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration)
        guard !videoTracks.isEmpty, duration.isNumeric, duration.seconds > 0 else {
            throw LiveProgramMovieWriterError.unreadableMovie
        }
        return outputURL
    }

    func abort() async {
        guard !isFinished else { return }
        isFinished = true
        switch writer.status {
        case .writing:
            videoInput.markAsFinished()
            audioInputs.values.forEach { $0.markAsFinished() }
            await writer.finishWriting()
        case .unknown:
            writer.cancelWriting()
        case .completed, .failed, .cancelled:
            break
        @unknown default:
            writer.cancelWriting()
        }
    }

    private func throwIfWriterFailed() throws {
        guard writer.status != .failed else {
            throw LiveProgramMovieWriterError.appendFailed(
                writer.error?.localizedDescription ?? "Unknown writer error."
            )
        }
    }

    private func isUsable(_ time: CMTime) -> Bool {
        time.isNumeric && time.seconds.isFinite
    }

    private func isNewer(_ time: CMTime, than previous: CMTime?) -> Bool {
        previous.map { CMTimeCompare(time, $0) > 0 } ?? true
    }
}

struct LiveProgramArchiveFailure: Error, Sendable {
    let message: String
}

actor LiveProgramArchiveSession: LiveProgramArchiveSink {
    typealias Completion = @MainActor @Sendable (Result<URL, LiveProgramArchiveFailure>) async -> Void

    private let writer: any LiveProgramMovieWriting
    private let completion: Completion
    private var isTerminal = false

    init(writer: any LiveProgramMovieWriting, completion: @escaping Completion) {
        self.writer = writer
        self.completion = completion
    }

    func appendVideo(_ sampleBuffer: SendableSampleBuffer) async {
        guard !isTerminal else { return }
        do {
            try await writer.appendVideo(sampleBuffer)
        } catch {
            await terminate(with: error.localizedDescription)
        }
    }

    func appendAudio(_ sampleBuffer: SendableSampleBuffer, track: UInt8) async {
        guard !isTerminal else { return }
        do {
            try await writer.appendAudio(sampleBuffer, track: track)
        } catch {
            await terminate(with: error.localizedDescription)
        }
    }

    func fail(_ message: String) async {
        await terminate(with: message)
    }

    func finish() async {
        guard !isTerminal else { return }
        isTerminal = true
        do {
            let url = try await writer.finish()
            await completion(.success(url))
        } catch {
            await completion(.failure(.init(message: error.localizedDescription)))
        }
    }

    private func terminate(with message: String) async {
        guard !isTerminal else { return }
        isTerminal = true
        await writer.abort()
        await completion(.failure(.init(message: message)))
    }
}

@MainActor
final class LiveProgramArchiveCoordinator: ObservableObject {
    @Published private(set) var state: LiveProgramArchiveState = .idle

    private let projectStore: RecordingProjectStore

    init(projectStore: RecordingProjectStore = RecordingProjectStore()) {
        self.projectStore = projectStore
    }

    func start(
        request: CaptureRequest,
        streamConfiguration: YouTubeStreamConfiguration,
        audioConfiguration: LiveStreamAudioConfiguration
    ) -> LiveProgramArchiveSession? {
        guard !state.isActive else { return nil }
        state = .preparing
        var preparedProject: RecordingProject?
        do {
            let project = try projectStore.createProgramArchiveProject(request: request)
            preparedProject = project
            let outputURL = project.rootURL.appending(path: RecordingTrackDescriptor.program.relativePath)
            let writer = try LiveProgramMovieWriter(configuration: .init(
                outputURL: outputURL,
                canvasSize: streamConfiguration.canvasSize,
                frameRate: streamConfiguration.frameRate,
                videoBitRate: streamConfiguration.videoBitRate,
                capturesSystemAudio: audioConfiguration.capturesSystemAudio,
                capturesMicrophone: audioConfiguration.capturesMicrophone
            ))
            try projectStore.markStarted(trackID: RecordingTrackDescriptor.program.id, in: project)
            state = .recording(project.rootURL)
            return LiveProgramArchiveSession(writer: writer) { result in
                await self.complete(result, project: project)
            }
        } catch {
            if let preparedProject {
                try? projectStore.markFailure(
                    trackID: RecordingTrackDescriptor.program.id,
                    detail: error.localizedDescription,
                    in: preparedProject
                )
                try? projectStore.markInterrupted(preparedProject, detail: error.localizedDescription)
            }
            state = .failed(error.localizedDescription)
            return nil
        }
    }

    private func complete(
        _ result: Result<URL, LiveProgramArchiveFailure>,
        project: RecordingProject
    ) async {
        state = .finalizing(project.rootURL)
        switch result {
        case .success:
            do {
                try projectStore.markFinished(trackID: RecordingTrackDescriptor.program.id, in: project)
                try projectStore.close(project, replacingTracks: [.program])
                state = .ready(project.rootURL)
            } catch {
                try? projectStore.markFailure(
                    trackID: RecordingTrackDescriptor.program.id,
                    detail: error.localizedDescription,
                    in: project
                )
                try? projectStore.markInterrupted(project, detail: error.localizedDescription)
                state = .failed(error.localizedDescription)
            }
        case .failure(let failure):
            try? projectStore.markFailure(
                trackID: RecordingTrackDescriptor.program.id,
                detail: failure.message,
                in: project
            )
            try? projectStore.markInterrupted(project, detail: failure.message)
            state = .failed(failure.message)
        }
    }
}
