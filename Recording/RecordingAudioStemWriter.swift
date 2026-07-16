@preconcurrency import AVFoundation
import Foundation

enum RecordingAudioStemSource: String, CaseIterable, Hashable, Sendable {
    case systemAudio
    case microphone
}

struct RecordingAudioStemWriterConfiguration: Sendable {
    let outputURL: URL
    let capturesSystemAudio: Bool
    let capturesMicrophone: Bool
}

struct RecordingAudioStemWriterResult: Sendable {
    let outputURL: URL
    let sampleCounts: [RecordingAudioStemSource: Int]
    let persistentTrackIDs: [RecordingAudioStemSource: CMPersistentTrackID]
}

enum RecordingAudioStemWriterError: LocalizedError, Equatable {
    case cannotAddInput
    case couldNotStart(String)
    case timelineAnchorUnavailable
    case preAnchorOverflow
    case backpressure(RecordingAudioStemSource)
    case appendFailed(String)
    case finishFailed(String)
    case unreadableMovie

    var errorDescription: String? {
        switch self {
        case .cannotAddInput:
            "The audio stem movie could not accept the selected audio sources."
        case .couldNotStart(let detail):
            "The audio stem movie could not start. \(detail)"
        case .timelineAnchorUnavailable:
            "The audio stems did not receive the primary screen clock anchor."
        case .preAnchorOverflow:
            "Audio arrived without a screen clock anchor for too long."
        case .backpressure(let source):
            "The audio stem writer could not keep up with \(source.label)."
        case .appendFailed(let detail):
            "The audio stem writer stopped accepting media. \(detail)"
        case .finishFailed(let detail):
            "The audio stem movie could not be finalized. \(detail)"
        case .unreadableMovie:
            "The finalized audio stem movie is not readable."
        }
    }
}

extension RecordingAudioStemSource {
    var label: String {
        switch self {
        case .systemAudio: "system audio"
        case .microphone: "microphone audio"
        }
    }
}

/// Thread-safe writer for the primary ScreenCaptureKit stream. Both inputs share
/// the first screen sample's source time, so their original PTS preserves sync.
final class RecordingAudioStemWriter: @unchecked Sendable {
    static let sourceMetadataPrefix = "ua.com.rmarinsky.studiorecorder.audio-source."

    private let lock = NSLock()
    private let writer: AVAssetWriter
    private let inputs: [RecordingAudioStemSource: AVAssetWriterInput]
    private let expectedSources: Set<RecordingAudioStemSource>
    private let sourceOrder: [RecordingAudioStemSource]
    private let outputURL: URL
    private var pendingBeforeAnchor: [RecordingAudioStemSource: [CMSampleBuffer]] = [:]
    private var startedAt: CMTime?
    private var lastTimes: [RecordingAudioStemSource: CMTime] = [:]
    private var sampleCounts: [RecordingAudioStemSource: Int] = [:]
    private var failure: RecordingAudioStemWriterError?
    private var isFinished = false

    init(
        configuration: RecordingAudioStemWriterConfiguration,
        fileManager: FileManager = .default
    ) throws {
        outputURL = configuration.outputURL
        try? fileManager.removeItem(at: outputURL)
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        writer.initialMovieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

        var expectedSources: Set<RecordingAudioStemSource> = []
        if configuration.capturesSystemAudio { expectedSources.insert(.systemAudio) }
        if configuration.capturesMicrophone { expectedSources.insert(.microphone) }
        self.expectedSources = expectedSources
        sourceOrder = RecordingAudioStemSource.allCases.filter(expectedSources.contains)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        var inputs: [RecordingAudioStemSource: AVAssetWriterInput] = [:]
        for source in sourceOrder {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            let sourceMarker = AVMutableMetadataItem()
            sourceMarker.identifier = .quickTimeMetadataDisplayName
            sourceMarker.value = "\(Self.sourceMetadataPrefix)\(source.rawValue)" as NSString
            input.metadata = [sourceMarker]
            guard writer.canAdd(input) else { throw RecordingAudioStemWriterError.cannotAddInput }
            writer.add(input)
            inputs[source] = input
            sampleCounts[source] = 0
        }
        self.inputs = inputs
    }

    @discardableResult
    func establishTimeline(at screenPresentationTime: CMTime) throws -> Bool {
        try lock.withLock {
            guard failure == nil else { throw failure! }
            guard !isFinished else { return false }
            guard startedAt == nil else { return false }
            guard screenPresentationTime.isValid,
                  screenPresentationTime.isNumeric else {
                throw RecordingAudioStemWriterError.timelineAnchorUnavailable
            }
            guard writer.startWriting() else {
                let error = RecordingAudioStemWriterError.couldNotStart(
                    writer.error?.localizedDescription ?? "Unknown writer error."
                )
                failure = error
                throw error
            }
            writer.startSession(atSourceTime: screenPresentationTime)
            startedAt = screenPresentationTime
            for source in RecordingAudioStemSource.allCases {
                for sampleBuffer in pendingBeforeAnchor.removeValue(forKey: source) ?? [] {
                    try appendLocked(sampleBuffer, source: source)
                }
            }
            return true
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer, source: RecordingAudioStemSource) throws {
        try lock.withLock {
            guard expectedSources.contains(source), !isFinished else { return }
            if let failure { throw failure }
            guard startedAt != nil else {
                var pending = pendingBeforeAnchor[source] ?? []
                guard pending.count < 120 else {
                    failure = .preAnchorOverflow
                    throw RecordingAudioStemWriterError.preAnchorOverflow
                }
                pending.append(sampleBuffer)
                pendingBeforeAnchor[source] = pending
                return
            }
            try appendLocked(sampleBuffer, source: source)
        }
    }

    func finish() async throws -> RecordingAudioStemWriterResult {
        let preflight: RecordingAudioStemWriterError? = lock.withLock {
            guard !isFinished else { return failure }
            isFinished = true
            guard startedAt != nil else {
                failure = failure ?? .timelineAnchorUnavailable
                writer.cancelWriting()
                return failure
            }
            if failure != nil {
                writer.cancelWriting()
                return failure
            }
            do {
                for source in expectedSources where sampleCounts[source, default: 0] == 0 {
                    try appendEmptySourceSilenceLocked(source: source)
                }
            } catch {
                let writerError = error as? RecordingAudioStemWriterError
                    ?? .appendFailed(error.localizedDescription)
                failure = writerError
                writer.cancelWriting()
                return writerError
            }
            inputs.values.forEach { $0.markAsFinished() }
            return nil
        }
        if let preflight { throw preflight }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw RecordingAudioStemWriterError.finishFailed(
                writer.error?.localizedDescription ?? "Unknown writer error."
            )
        }
        let counts = lock.withLock { sampleCounts }
        let asset = AVURLAsset(url: outputURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)
        guard tracks.count == expectedSources.count,
              duration.isNumeric,
              duration > .zero else {
            throw RecordingAudioStemWriterError.unreadableMovie
        }
        var persistentTrackIDs: [RecordingAudioStemSource: CMPersistentTrackID] = [:]
        for track in tracks {
            let metadata = try await track.load(.metadata)
            let markers = AVMetadataItem.metadataItems(
                from: metadata,
                filteredByIdentifier: .quickTimeMetadataDisplayName
            )
            var resolvedSource: RecordingAudioStemSource?
            for marker in markers {
                guard let value = try await marker.load(.stringValue),
                      value.hasPrefix(Self.sourceMetadataPrefix) else { continue }
                resolvedSource = RecordingAudioStemSource(
                    rawValue: String(value.dropFirst(Self.sourceMetadataPrefix.count))
                )
                if resolvedSource != nil { break }
            }
            guard let resolvedSource,
                  expectedSources.contains(resolvedSource),
                  persistentTrackIDs[resolvedSource] == nil else {
                throw RecordingAudioStemWriterError.unreadableMovie
            }
            persistentTrackIDs[resolvedSource] = track.trackID
        }
        guard Set(persistentTrackIDs.keys) == expectedSources else {
            throw RecordingAudioStemWriterError.unreadableMovie
        }
        return RecordingAudioStemWriterResult(
            outputURL: outputURL,
            sampleCounts: counts,
            persistentTrackIDs: persistentTrackIDs
        )
    }

    func abort() {
        lock.withLock {
            guard !isFinished else { return }
            isFinished = true
            writer.cancelWriting()
        }
    }

    private func appendLocked(
        _ sampleBuffer: CMSampleBuffer,
        source: RecordingAudioStemSource
    ) throws {
        guard let startedAt,
              let input = inputs[source] else { return }
        let time = sampleBuffer.presentationTimeStamp
        guard time.isValid,
              time.isNumeric,
              CMTimeCompare(time, startedAt) >= 0,
              lastTimes[source].map({ CMTimeCompare(time, $0) > 0 }) ?? true else { return }
        if lastTimes[source] == nil,
           CMTimeCompare(time, startedAt) > 0 {
            try appendTimelineSilenceLocked(
                matching: sampleBuffer,
                source: source,
                from: startedAt,
                to: time,
                input: input
            )
        }
        guard waitUntilReady(input) else {
            failure = .backpressure(source)
            throw RecordingAudioStemWriterError.backpressure(source)
        }
        guard input.append(sampleBuffer) else {
            let error = RecordingAudioStemWriterError.appendFailed(
                writer.error?.localizedDescription ?? "Unknown append error."
            )
            failure = error
            throw error
        }
        lastTimes[source] = time
        sampleCounts[source, default: 0] += 1
    }

    private func appendTimelineSilenceLocked(
        matching sampleBuffer: CMSampleBuffer,
        source: RecordingAudioStemSource,
        from startTime: CMTime,
        to endTime: CMTime,
        input: AVAssetWriterInput
    ) throws {
        guard let formatDescription = sampleBuffer.formatDescription,
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: streamDescription) else {
            throw RecordingAudioStemWriterError.appendFailed("Could not create a silent timeline anchor.")
        }
        let maximumChunkFrames = AVAudioFrameCount(format.sampleRate * 30)
        var presentationTime = startTime
        while CMTimeCompare(presentationTime, endTime) < 0 {
            let remainingSeconds = (endTime - presentationTime).seconds
            let remainingFrames = AVAudioFrameCount(
                max(1, (remainingSeconds * format.sampleRate).rounded(.down))
            )
            let frameCount = min(remainingFrames, maximumChunkFrames)
            let silence = try silentSampleBuffer(
                formatDescription: formatDescription,
                format: format,
                at: presentationTime,
                frameCount: frameCount
            )
            guard waitUntilReady(input) else {
                failure = .backpressure(source)
                throw RecordingAudioStemWriterError.backpressure(source)
            }
            guard input.append(silence) else {
                let error = RecordingAudioStemWriterError.appendFailed(
                    writer.error?.localizedDescription ?? "Could not anchor \(source.label) to the screen timeline."
                )
                failure = error
                throw error
            }
            presentationTime = presentationTime + CMTime(
                value: CMTimeValue(frameCount),
                timescale: CMTimeScale(format.sampleRate)
            )
        }
        lastTimes[source] = presentationTime
    }

    private func appendEmptySourceSilenceLocked(source: RecordingAudioStemSource) throws {
        guard let startedAt,
              let input = inputs[source],
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 2,
                interleaved: false
              ) else { return }
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
            throw RecordingAudioStemWriterError.appendFailed("Could not create a silent timeline anchor.")
        }
        let silence = try silentSampleBuffer(
            formatDescription: formatDescription,
            format: format,
            at: startedAt,
            frameCount: 1_024
        )
        guard waitUntilReady(input) else {
            throw RecordingAudioStemWriterError.backpressure(source)
        }
        guard input.append(silence) else {
            throw RecordingAudioStemWriterError.appendFailed(
                writer.error?.localizedDescription ?? "Could not preserve an empty \(source.label) track."
            )
        }
    }

    private func silentSampleBuffer(
        formatDescription: CMAudioFormatDescription,
        format: AVAudioFormat,
        at presentationTime: CMTime,
        frameCount: AVAudioFrameCount
    ) throws -> CMSampleBuffer {
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw RecordingAudioStemWriterError.appendFailed("Could not create a silent timeline anchor.")
        }
        pcmBuffer.frameLength = pcmBuffer.frameCapacity
        for buffer in UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList) {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var silence: CMSampleBuffer?
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
            sampleBufferOut: &silence
        ) == noErr,
        let silence,
        CMSampleBufferSetDataBufferFromAudioBufferList(
            silence,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            bufferList: pcmBuffer.audioBufferList
        ) == noErr else {
            throw RecordingAudioStemWriterError.appendFailed("Could not encode a silent timeline anchor.")
        }
        return silence
    }

    private func waitUntilReady(
        _ input: AVAssetWriterInput,
        timeout: TimeInterval = 2
    ) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !input.isReadyForMoreMediaData,
              writer.status == .writing,
              ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        return input.isReadyForMoreMediaData
    }
}
