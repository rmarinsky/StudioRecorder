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
    case audioFlattenFailed(String)
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
        case .audioFlattenFailed(let detail):
            "The local movie audio could not be combined safely. \(detail)"
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

private struct MediaSampleTimeline {
    let count: Int
    let first: CMTime?
    let end: CMTime?
}

private final class FlattenCancellationContext: @unchecked Sendable {
    let reader: AVAssetReader
    let writer: AVAssetWriter

    init(reader: AVAssetReader, writer: AVAssetWriter) {
        self.reader = reader
        self.writer = writer
    }

    func cancel() {
        reader.cancelReading()
        writer.cancelWriting()
    }
}

actor LiveProgramMovieWriter: LiveProgramMovieWriting {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInputs: [UInt8: AVAssetWriterInput]
    private let outputURL: URL
    private let fileManager: FileManager
    private let expectsAudio: Bool
    private var startedAt: CMTime?
    private var lastVideoTime: CMTime?
    private var lastAudioTimes: [UInt8: CMTime] = [:]
    private var videoFrameCount = 0
    private var isFinished = false
    private var activeFlattenReader: AVAssetReader?
    private var activeFlattenWriter: AVAssetWriter?

    init(
        configuration: LiveProgramMovieWriterConfiguration,
        fileManager: FileManager = .default
    ) throws {
        outputURL = configuration.outputURL
        self.fileManager = fileManager
        expectsAudio = configuration.capturesSystemAudio || configuration.capturesMicrophone
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
        try await appendSilentAudioIfNeeded()
        videoInput.markAsFinished()
        audioInputs.values.forEach { $0.markAsFinished() }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw LiveProgramMovieWriterError.finishFailed(
                writer.error?.localizedDescription ?? "Unknown writer error."
            )
        }
        try await flattenAudioTracksIfNeeded()
        let asset = AVURLAsset(url: outputURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)
        guard videoTracks.count == 1,
              audioTracks.count == (expectsAudio ? 1 : 0),
              duration.isNumeric,
              duration.seconds > 0 else {
            throw LiveProgramMovieWriterError.unreadableMovie
        }
        return outputURL
    }

    func abort() async {
        if let activeFlattenReader {
            activeFlattenReader.cancelReading()
            activeFlattenWriter?.cancelWriting()
            self.activeFlattenReader = nil
            activeFlattenWriter = nil
            return
        }
        if isFinished {
            if writer.status == .writing {
                writer.cancelWriting()
            }
            return
        }
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
        guard writer.status != .failed, writer.status != .cancelled else {
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

    private func appendSilentAudioIfNeeded() async throws {
        guard expectsAudio,
              lastAudioTimes.isEmpty,
              let startedAt,
              let input = audioInputs[0] ?? audioInputs[1] else { return }
        var times = [startedAt]
        if let lastVideoTime,
           CMTimeCompare(lastVideoTime, startedAt) > 0 {
            times.append(lastVideoTime)
        }
        for time in times {
            while !input.isReadyForMoreMediaData {
                try throwIfWriterFailed()
                try await Task.sleep(for: .milliseconds(1))
            }
            let silence = try makeSilentAudioSampleBuffer(at: time)
            guard input.append(silence) else {
                throw LiveProgramMovieWriterError.appendFailed(
                    writer.error?.localizedDescription ?? "Silent audio append failed."
                )
            }
        }
    }

    private func makeSilentAudioSampleBuffer(at time: CMTime) throws -> CMSampleBuffer {
        let frameCount: AVAudioFrameCount = 1_024
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ),
        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw LiveProgramMovieWriterError.audioFlattenFailed("A silent audio format could not be created.")
        }
        pcmBuffer.frameLength = frameCount
        for buffer in UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList) {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }

        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: format.streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr,
        let formatDescription else {
            throw LiveProgramMovieWriterError.audioFlattenFailed("A silent audio description could not be created.")
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr,
        let sampleBuffer,
        CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            bufferList: pcmBuffer.audioBufferList
        ) == noErr else {
            throw LiveProgramMovieWriterError.audioFlattenFailed("A silent audio buffer could not be created.")
        }
        return sampleBuffer
    }

    private func flattenAudioTracksIfNeeded() async throws {
        let sourceAsset = AVURLAsset(url: outputURL)
        let audioTracks = try await sourceAsset.loadTracks(withMediaType: .audio)
        guard audioTracks.count > 1 else { return }
        guard let videoTrack = try await sourceAsset.loadTracks(withMediaType: .video).first else {
            throw LiveProgramMovieWriterError.audioFlattenFailed("The composed video track is missing.")
        }

        let temporaryURL = outputURL.deletingLastPathComponent().appending(
            path: ".\(outputURL.deletingPathExtension().lastPathComponent)-flattened-\(UUID().uuidString).mov"
        )
        let backupName = ".\(outputURL.lastPathComponent)-pre-flatten-\(UUID().uuidString)"
        let backupURL = outputURL.deletingLastPathComponent().appending(path: backupName)
        try? fileManager.removeItem(at: temporaryURL)
        defer {
            try? fileManager.removeItem(at: temporaryURL)
        }

        do {
            let reader = try AVAssetReader(asset: sourceAsset)
            let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            videoOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(videoOutput) else {
                throw LiveProgramMovieWriterError.audioFlattenFailed("The composed video could not be read.")
            }
            reader.add(videoOutput)

            let audioOutput = AVAssetReaderAudioMixOutput(
                audioTracks: audioTracks,
                audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            )
            let audioMix = AVMutableAudioMix()
            let perSourceGain = 1 / Float(audioTracks.count)
            audioMix.inputParameters = audioTracks.map { track in
                let parameters = AVMutableAudioMixInputParameters(track: track)
                parameters.setVolume(perSourceGain, at: .zero)
                return parameters
            }
            audioOutput.audioMix = audioMix
            guard reader.canAdd(audioOutput) else {
                throw LiveProgramMovieWriterError.audioFlattenFailed("The selected audio sources could not be mixed.")
            }
            reader.add(audioOutput)

            let flattenedWriter = try AVAssetWriter(outputURL: temporaryURL, fileType: .mov)
            flattenedWriter.initialMovieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
            flattenedWriter.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
            let videoFormat = try await videoTrack.load(.formatDescriptions).first
            let flattenedVideoInput = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: nil,
                sourceFormatHint: videoFormat
            )
            let flattenedAudioInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128_000,
                ]
            )
            guard flattenedWriter.canAdd(flattenedVideoInput),
                  flattenedWriter.canAdd(flattenedAudioInput) else {
                throw LiveProgramMovieWriterError.audioFlattenFailed("The flattened media tracks could not be created.")
            }
            flattenedWriter.add(flattenedVideoInput)
            flattenedWriter.add(flattenedAudioInput)
            activeFlattenReader = reader
            activeFlattenWriter = flattenedWriter
            defer {
                if reader.status == .reading {
                    reader.cancelReading()
                }
                if flattenedWriter.status == .writing {
                    flattenedWriter.cancelWriting()
                }
                activeFlattenReader = nil
                activeFlattenWriter = nil
            }
            guard flattenedWriter.startWriting(), reader.startReading() else {
                throw LiveProgramMovieWriterError.audioFlattenFailed(
                    flattenedWriter.error?.localizedDescription
                        ?? reader.error?.localizedDescription
                        ?? "The flattening session could not start."
                )
            }
            flattenedWriter.startSession(atSourceTime: .zero)

            var nextVideo = videoOutput.copyNextSampleBuffer()
            var nextAudio = audioOutput.copyNextSampleBuffer()
            var copiedVideoCount = 0
            var firstCopiedVideoTime: CMTime?
            var copiedVideoEndTime: CMTime?
            var firstCopiedAudioTime: CMTime?
            var copiedAudioEndTime: CMTime?
            while nextVideo != nil || nextAudio != nil {
                try Task.checkCancellation()
                try ensureFlatteningIsActive(reader: reader, writer: flattenedWriter)
                let appendsVideo: Bool
                if let video = nextVideo, let audio = nextAudio {
                    appendsVideo = CMTimeCompare(
                        video.presentationTimeStamp,
                        audio.presentationTimeStamp
                    ) <= 0
                } else {
                    appendsVideo = nextVideo != nil
                }
                let input = appendsVideo ? flattenedVideoInput : flattenedAudioInput
                guard input.isReadyForMoreMediaData else {
                    try await Task.sleep(for: .milliseconds(1))
                    continue
                }
                let sample = appendsVideo ? nextVideo : nextAudio
                guard let sample, input.append(sample) else {
                    throw LiveProgramMovieWriterError.audioFlattenFailed(
                        flattenedWriter.error?.localizedDescription ?? "A flattened media sample was rejected."
                    )
                }
                if appendsVideo {
                    copiedVideoCount += 1
                    firstCopiedVideoTime = firstCopiedVideoTime ?? sample.presentationTimeStamp
                    copiedVideoEndTime = sample.endPresentationTimeStamp
                    nextVideo = videoOutput.copyNextSampleBuffer()
                } else {
                    firstCopiedAudioTime = firstCopiedAudioTime ?? sample.presentationTimeStamp
                    copiedAudioEndTime = sample.endPresentationTimeStamp
                    nextAudio = audioOutput.copyNextSampleBuffer()
                }
            }
            flattenedVideoInput.markAsFinished()
            flattenedAudioInput.markAsFinished()
            let cancellationContext = FlattenCancellationContext(
                reader: reader,
                writer: flattenedWriter
            )
            await withTaskCancellationHandler {
                await flattenedWriter.finishWriting()
            } onCancel: {
                cancellationContext.cancel()
            }
            try Task.checkCancellation()
            guard reader.status == .completed,
                  flattenedWriter.status == .completed else {
                throw LiveProgramMovieWriterError.audioFlattenFailed(
                    flattenedWriter.error?.localizedDescription
                        ?? reader.error?.localizedDescription
                        ?? "The flattened movie did not finish."
                )
            }
            let flattenedAsset = AVURLAsset(url: temporaryURL)
            let flattenedVideoTracks = try await flattenedAsset.loadTracks(withMediaType: .video)
            let flattenedAudioTracks = try await flattenedAsset.loadTracks(withMediaType: .audio)
            let sourceDuration = try await sourceAsset.load(.duration)
            let flattenedDuration = try await flattenedAsset.load(.duration)
            let isReadable = try await flattenedAsset.load(.isReadable)
            let sourceVideoFormat = try await videoTrack.load(.formatDescriptions).first
            let flattenedVideoFormat = try await flattenedVideoTracks.first?.load(.formatDescriptions).first
            let flattenedVideoTimeline: MediaSampleTimeline? = if let track = flattenedVideoTracks.first {
                try await sampleTimeline(asset: flattenedAsset, track: track)
            } else { nil }
            let flattenedAudioTimeline: MediaSampleTimeline? = if let track = flattenedAudioTracks.first {
                try await sampleTimeline(asset: flattenedAsset, track: track)
            } else { nil }
            let durationsMatch = sourceDuration.isNumeric
                && flattenedDuration.isNumeric
                && abs(sourceDuration.seconds - flattenedDuration.seconds) <= 0.05
            guard isReadable,
                  flattenedVideoTracks.count == 1,
                  flattenedAudioTracks.count == 1,
                  flattenedDuration.seconds > 0,
                  durationsMatch,
                  sourceVideoFormat.map(CMFormatDescriptionGetMediaSubType)
                    == flattenedVideoFormat.map(CMFormatDescriptionGetMediaSubType),
                  flattenedVideoTimeline?.count == copiedVideoCount,
                  timesMatch(flattenedVideoTimeline?.first, firstCopiedVideoTime),
                  timesMatch(flattenedVideoTimeline?.end, copiedVideoEndTime),
                  timesMatch(flattenedAudioTimeline?.first, firstCopiedAudioTime, tolerance: 1.0 / 48_000.0 * 1_024),
                  timesMatch(flattenedAudioTimeline?.end, copiedAudioEndTime, tolerance: 1.0 / 48_000.0 * 1_024) else {
                throw LiveProgramMovieWriterError.audioFlattenFailed("The flattened movie failed media verification.")
            }
            _ = try fileManager.replaceItemAt(
                outputURL,
                withItemAt: temporaryURL,
                backupItemName: backupName,
                options: [.withoutDeletingBackupItem]
            )
            do {
                try await verifyFlattenedMovie(
                    at: outputURL,
                    matchingDuration: sourceDuration,
                    audioStart: firstCopiedAudioTime,
                    audioEnd: copiedAudioEndTime
                )
                try? fileManager.removeItem(at: backupURL)
            } catch {
                try? fileManager.removeItem(at: outputURL)
                if fileManager.fileExists(atPath: backupURL.path) {
                    try fileManager.moveItem(at: backupURL, to: outputURL)
                }
                throw error
            }
        } catch is CancellationError {
            throw LiveProgramMovieWriterError.audioFlattenFailed("Audio finalization was cancelled.")
        } catch let error as LiveProgramMovieWriterError {
            throw error
        } catch {
            throw LiveProgramMovieWriterError.audioFlattenFailed(error.localizedDescription)
        }
    }

    private func ensureFlatteningIsActive(
        reader: AVAssetReader,
        writer: AVAssetWriter
    ) throws {
        if reader.status == .failed || reader.status == .cancelled
            || writer.status == .failed || writer.status == .cancelled {
            throw LiveProgramMovieWriterError.audioFlattenFailed(
                writer.error?.localizedDescription
                    ?? reader.error?.localizedDescription
                    ?? "Audio finalization was interrupted."
            )
        }
    }

    private func verifyFlattenedMovie(
        at url: URL,
        matchingDuration sourceDuration: CMTime,
        audioStart: CMTime?,
        audioEnd: CMTime?
    ) async throws {
        let asset = AVURLAsset(url: url)
        let isReadable = try await asset.load(.isReadable)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)
        let audioTimeline: MediaSampleTimeline? = if let track = audioTracks.first {
            try await sampleTimeline(asset: asset, track: track)
        } else { nil }
        guard isReadable,
              videoTracks.count == 1,
              audioTracks.count == 1,
              duration.isNumeric,
              duration.seconds > 0,
              abs(duration.seconds - sourceDuration.seconds) <= 0.05,
              timesMatch(audioTimeline?.first, audioStart, tolerance: 1.0 / 48_000.0 * 1_024),
              timesMatch(audioTimeline?.end, audioEnd, tolerance: 1.0 / 48_000.0 * 1_024) else {
            throw LiveProgramMovieWriterError.audioFlattenFailed(
                "The installed flattened movie failed media verification."
            )
        }
    }

    private func sampleTimeline(
        asset: AVAsset,
        track: AVAssetTrack
    ) async throws -> MediaSampleTimeline {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw LiveProgramMovieWriterError.audioFlattenFailed("The flattened video could not be verified.")
        }
        reader.add(output)
        activeFlattenReader = reader
        activeFlattenWriter = nil
        defer {
            if reader.status == .reading {
                reader.cancelReading()
            }
            if activeFlattenReader === reader {
                activeFlattenReader = nil
            }
        }
        guard reader.startReading() else {
            throw LiveProgramMovieWriterError.audioFlattenFailed(
                reader.error?.localizedDescription ?? "The flattened video verification could not start."
            )
        }
        var count = 0
        var first: CMTime?
        var end: CMTime?
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            count += 1
            first = first ?? sample.presentationTimeStamp
            end = sample.endPresentationTimeStamp
            if count.isMultiple(of: 128) {
                await Task.yield()
            }
        }
        guard reader.status == .completed else {
            throw LiveProgramMovieWriterError.audioFlattenFailed(
                reader.error?.localizedDescription ?? "The flattened video verification did not finish."
            )
        }
        return MediaSampleTimeline(count: count, first: first, end: end)
    }

    private func timesMatch(
        _ lhs: CMTime?,
        _ rhs: CMTime?,
        tolerance: TimeInterval = 1.0 / 600.0
    ) -> Bool {
        guard let lhs, let rhs, lhs.isNumeric, rhs.isNumeric else { return lhs == nil && rhs == nil }
        return abs(lhs.seconds - rhs.seconds) <= tolerance
    }
}

private extension CMSampleBuffer {
    var endPresentationTimeStamp: CMTime {
        CMTimeAdd(presentationTimeStamp, duration)
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
