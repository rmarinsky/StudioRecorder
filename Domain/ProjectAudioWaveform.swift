import Accelerate
@preconcurrency import AVFoundation
import Foundation

enum WhisperAudioExtractionError: LocalizedError {
    case unreadableAudio
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .unreadableAudio: "The recording has no readable audio for transcription."
        case .tooLarge: "The recording is too long for a single transcription WAV file."
        }
    }
}

struct WhisperAudioExtractor {
    func writeWAV(from sourceURL: URL, to destinationURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw WhisperAudioExtractionError.unreadableAudio }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { throw WhisperAudioExtractionError.unreadableAudio }
        reader.add(output)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: destinationURL.path, contents: Data(repeating: 0, count: 44))
        do {
            let file = try FileHandle(forWritingTo: destinationURL)
            defer { try? file.close() }
            try file.seekToEnd()
            guard reader.startReading() else { throw WhisperAudioExtractionError.unreadableAudio }
            defer { reader.cancelReading() }
            var byteCount: UInt64 = 0
            var firstSample = true
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                if firstSample {
                    firstSample = false
                    let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    if start.isFinite && start > 0 {
                        guard start < Double(UInt32.max / 2) / 16_000 else {
                            throw WhisperAudioExtractionError.tooLarge
                        }
                        let leadingBytes = Int((start * 16_000).rounded()) * 2
                        var remaining = leadingBytes
                        while remaining > 0 {
                            let count = min(remaining, 1_048_576)
                            try file.write(contentsOf: Data(repeating: 0, count: count))
                            remaining -= count
                        }
                        byteCount += UInt64(leadingBytes)
                    }
                }
                guard let block = CMSampleBufferGetDataBuffer(sample) else {
                    throw WhisperAudioExtractionError.unreadableAudio
                }
                let length = CMBlockBufferGetDataLength(block)
                var bytes = Data(count: length)
                let status = bytes.withUnsafeMutableBytes { destination in
                    guard let address = destination.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
                    return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: address)
                }
                guard status == kCMBlockBufferNoErr else { throw WhisperAudioExtractionError.unreadableAudio }
                byteCount += UInt64(length)
                guard byteCount <= UInt32.max - 36 else { throw WhisperAudioExtractionError.tooLarge }
                try file.write(contentsOf: bytes)
            }
            guard reader.status == .completed, byteCount > 0 else {
                throw WhisperAudioExtractionError.unreadableAudio
            }
            try file.seek(toOffset: 0)
            try file.write(contentsOf: wavHeader(byteCount: UInt32(byteCount)))
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    private func wavHeader(byteCount: UInt32) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(byteCount + UInt32(36))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(16_000))
        append(UInt32(32_000))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(byteCount)
        return data
    }
}

struct ProjectAudioWaveformBucket: Codable, Equatable, Sendable {
    let sourceStart: TimeInterval
    let duration: TimeInterval
    let peak: Float
    let rms: Float
    let isClipped: Bool
}

struct ProjectAudioWaveform: Codable, Equatable, Sendable {
    let duration: TimeInterval
    let buckets: [ProjectAudioWaveformBucket]

    var clippedBucketCount: Int { buckets.count(where: \.isClipped) }
    var clippedRegionCount: Int {
        var count = 0
        var wasClipped = false
        for bucket in buckets {
            if bucket.isClipped, !wasClipped { count += 1 }
            wasClipped = bucket.isClipped
        }
        return count
    }
}

enum ProjectSilenceDetector {
    static func candidates(
        in waveform: ProjectAudioWaveform,
        timeline: ProjectEditTimeline,
        minimumDuration: TimeInterval = 0.35,
        padding: TimeInterval = 0.08,
        rmsThreshold: Float = 0.012,
        peakThreshold: Float = 0.06
    ) -> [Range<TimeInterval>] {
        guard abs(waveform.duration - timeline.sourceDuration) < 0.1,
              minimumDuration > 0, padding >= 0 else { return [] }
        var result: [Range<TimeInterval>] = []
        var outputStart: TimeInterval = 0
        for segment in timeline.segments {
            let sourceEnd = segment.sourceStart + segment.duration
            var quietStart: TimeInterval?
            var quietEnd: TimeInterval = 0
            func finishQuietRun() {
                guard let quietStart, quietEnd - quietStart >= minimumDuration else { return }
                let start = quietStart + padding
                let end = quietEnd - padding
                if end > start {
                    let outputLower = outputStart + start - segment.sourceStart
                    let outputUpper = outputStart + end - segment.sourceStart
                    result.append(outputLower..<outputUpper)
                }
            }
            for bucket in waveform.buckets {
                let start = max(bucket.sourceStart, segment.sourceStart)
                let end = min(bucket.sourceStart + bucket.duration, sourceEnd)
                guard end > start else { continue }
                let quiet = bucket.rms <= rmsThreshold && bucket.peak <= peakThreshold
                if quiet {
                    if quietStart == nil { quietStart = start }
                    quietEnd = end
                } else {
                    finishQuietRun()
                    quietStart = nil
                }
            }
            finishQuietRun()
            outputStart += segment.duration
        }
        return result
    }
}

enum ProjectAudioWaveformError: LocalizedError, Equatable {
    case noAudioTrack
    case unreadableAudio

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: "This recording has no audio waveform to show."
        case .unreadableAudio: "Studio Recorder could not decode this recording's audio waveform."
        }
    }
}

actor ProjectAudioWaveformAnalyzer {
    private struct Cache: Codable {
        static let schemaVersion = 2

        let schemaVersion: Int
        let sourceFilename: String
        let sourceFileSize: Int64
        let sourceModificationTime: TimeInterval
        let bucketCount: Int
        let trackIndex: Int?
        let persistentTrackID: Int32?
        let waveform: ProjectAudioWaveform
    }

    private struct Accumulator {
        var peak: Float = 0
        var squareSum: Double = 0
        var sampleCount: Int64 = 0
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func waveform(
        for sourceURL: URL,
        cacheURL: URL,
        bucketCount: Int = 180,
        trackIndex: Int? = nil,
        persistentTrackID: Int32? = nil
    ) async throws -> ProjectAudioWaveform {
        let bucketCount = min(max(bucketCount, 2), 200_000)
        let metadata = try sourceMetadata(at: sourceURL)
        if let cached = readCache(
            at: cacheURL,
            sourceFilename: sourceURL.lastPathComponent,
            metadata: metadata,
            bucketCount: bucketCount,
            trackIndex: trackIndex,
            persistentTrackID: persistentTrackID
        ) {
            return cached
        }
        let waveform = try await analyze(
            sourceURL,
            bucketCount: bucketCount,
            trackIndex: trackIndex,
            persistentTrackID: persistentTrackID
        )
        let cache = Cache(
            schemaVersion: Cache.schemaVersion,
            sourceFilename: sourceURL.lastPathComponent,
            sourceFileSize: metadata.fileSize,
            sourceModificationTime: metadata.modificationTime,
            bucketCount: bucketCount,
            trackIndex: trackIndex,
            persistentTrackID: persistentTrackID,
            waveform: waveform
        )
        do {
            try fileManager.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(cache).write(to: cacheURL, options: .atomic)
        } catch {
            // The cache is disposable derived data; decoded audio remains useful without it.
        }
        return waveform
    }

    private func analyze(
        _ sourceURL: URL,
        bucketCount: Int,
        trackIndex: Int?,
        persistentTrackID: Int32?
    ) async throws -> ProjectAudioWaveform {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw ProjectAudioWaveformError.noAudioTrack }
        let selectedTracks: [AVAssetTrack]
        if let persistentTrackID {
            guard let track = tracks.first(where: { $0.trackID == persistentTrackID }) else {
                throw ProjectAudioWaveformError.noAudioTrack
            }
            selectedTracks = [track]
        } else if let trackIndex {
            guard tracks.indices.contains(trackIndex) else { throw ProjectAudioWaveformError.noAudioTrack }
            selectedTracks = [tracks[trackIndex]]
        } else {
            selectedTracks = tracks
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw ProjectAudioWaveformError.unreadableAudio
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: selectedTracks,
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        guard reader.canAdd(output) else { throw ProjectAudioWaveformError.unreadableAudio }
        reader.add(output)
        guard reader.startReading() else { throw ProjectAudioWaveformError.unreadableAudio }
        var accumulators = Array(repeating: Accumulator(), count: bucketCount)

        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try accumulate(
                sampleBuffer,
                duration: duration,
                into: &accumulators
            )
        }
        guard reader.status == .completed else {
            throw ProjectAudioWaveformError.unreadableAudio
        }

        let bucketDuration = duration / Double(bucketCount)
        return ProjectAudioWaveform(
            duration: duration,
            buckets: accumulators.enumerated().map { index, accumulator in
                ProjectAudioWaveformBucket(
                    sourceStart: Double(index) * bucketDuration,
                    duration: bucketDuration,
                    peak: accumulator.peak,
                    rms: accumulator.sampleCount > 0
                        ? Float(sqrt(accumulator.squareSum / Double(accumulator.sampleCount)))
                        : 0,
                    isClipped: accumulator.peak >= 0.98
                )
            }
        )
    }

    private func accumulate(
        _ sampleBuffer: CMSampleBuffer,
        duration: TimeInterval,
        into accumulators: inout [Accumulator]
    ) throws {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              stream.mSampleRate > 0,
              stream.mChannelsPerFrame > 0,
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw ProjectAudioWaveformError.unreadableAudio
        }
        var lengthAtOffset = 0
        var totalLength = 0
        var bytes: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            block,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &bytes
        ) == kCMBlockBufferNoErr,
        let bytes else {
            throw ProjectAudioWaveformError.unreadableAudio
        }
        guard totalLength > 0 else { return }
        if lengthAtOffset == totalLength {
            try accumulateSamples(
                UnsafeRawPointer(bytes).assumingMemoryBound(to: Float.self),
                byteCount: totalLength,
                sampleBuffer: sampleBuffer,
                stream: stream,
                duration: duration,
                into: &accumulators
            )
            return
        }

        var copiedBytes = Data(count: totalLength)
        let copyStatus = copiedBytes.withUnsafeMutableBytes { destination in
            guard let baseAddress = destination.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
            return CMBlockBufferCopyDataBytes(
                block,
                atOffset: 0,
                dataLength: totalLength,
                destination: baseAddress
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw ProjectAudioWaveformError.unreadableAudio
        }
        try copiedBytes.withUnsafeBytes { copied in
            guard let baseAddress = copied.baseAddress else { return }
            try accumulateSamples(
                baseAddress.assumingMemoryBound(to: Float.self),
                byteCount: copied.count,
                sampleBuffer: sampleBuffer,
                stream: stream,
                duration: duration,
                into: &accumulators
            )
        }
    }

    private func accumulateSamples(
        _ samples: UnsafePointer<Float>,
        byteCount: Int,
        sampleBuffer: CMSampleBuffer,
        stream: AudioStreamBasicDescription,
        duration: TimeInterval,
        into accumulators: inout [Accumulator]
    ) throws {
        let channels = Int(stream.mChannelsPerFrame)
        let frameCount = min(
            CMSampleBufferGetNumSamples(sampleBuffer),
            byteCount / (MemoryLayout<Float>.size * channels)
        )
        guard frameCount > 0 else { return }
        let startTime = max(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds, 0)
        let bucketDuration = duration / Double(accumulators.count)
        var frame = 0
        while frame < frameCount {
            let time = startTime + Double(frame) / stream.mSampleRate
            let bucketIndex = min(max(Int(time / bucketDuration), 0), accumulators.count - 1)
            let bucketEnd = Double(bucketIndex + 1) * bucketDuration
            let framesToBoundary = max(
                Int(ceil((bucketEnd - time) * stream.mSampleRate)),
                1
            )
            let groupFrames = min(frameCount - frame, framesToBoundary)
            let valueCount = groupFrames * channels
            let start = samples.advanced(by: frame * channels)
            var peak: Float = 0
            var squareSum: Float = 0
            vDSP_maxmgv(start, 1, &peak, vDSP_Length(valueCount))
            vDSP_svesq(start, 1, &squareSum, vDSP_Length(valueCount))
            accumulators[bucketIndex].peak = max(accumulators[bucketIndex].peak, peak)
            accumulators[bucketIndex].squareSum += Double(squareSum)
            accumulators[bucketIndex].sampleCount += Int64(valueCount)
            frame += groupFrames
        }
    }

    private func sourceMetadata(at url: URL) throws -> (fileSize: Int64, modificationTime: TimeInterval) {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (
            Int64(values.fileSize ?? 0),
            values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        )
    }

    private func readCache(
        at url: URL,
        sourceFilename: String,
        metadata: (fileSize: Int64, modificationTime: TimeInterval),
        bucketCount: Int,
        trackIndex: Int?,
        persistentTrackID: Int32?
    ) -> ProjectAudioWaveform? {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.schemaVersion == Cache.schemaVersion,
              cache.sourceFilename == sourceFilename,
              cache.sourceFileSize == metadata.fileSize,
              abs(cache.sourceModificationTime - metadata.modificationTime) < 0.001,
              cache.bucketCount == bucketCount,
              cache.trackIndex == trackIndex,
              cache.persistentTrackID == persistentTrackID else { return nil }
        return cache.waveform
    }
}
