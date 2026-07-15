import Accelerate
@preconcurrency import AVFoundation
import Foundation

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
        static let schemaVersion = 1

        let schemaVersion: Int
        let sourceFilename: String
        let sourceFileSize: Int64
        let sourceModificationTime: TimeInterval
        let bucketCount: Int
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
        bucketCount: Int = 180
    ) async throws -> ProjectAudioWaveform {
        let bucketCount = min(max(bucketCount, 2), 512)
        let metadata = try sourceMetadata(at: sourceURL)
        if let cached = readCache(
            at: cacheURL,
            sourceFilename: sourceURL.lastPathComponent,
            metadata: metadata,
            bucketCount: bucketCount
        ) {
            return cached
        }
        let waveform = try await analyze(sourceURL, bucketCount: bucketCount)
        let cache = Cache(
            schemaVersion: Cache.schemaVersion,
            sourceFilename: sourceURL.lastPathComponent,
            sourceFileSize: metadata.fileSize,
            sourceModificationTime: metadata.modificationTime,
            bucketCount: bucketCount,
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
        bucketCount: Int
    ) async throws -> ProjectAudioWaveform {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw ProjectAudioWaveformError.noAudioTrack }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw ProjectAudioWaveformError.unreadableAudio
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: tracks,
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
        bucketCount: Int
    ) -> ProjectAudioWaveform? {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.schemaVersion == Cache.schemaVersion,
              cache.sourceFilename == sourceFilename,
              cache.sourceFileSize == metadata.fileSize,
              abs(cache.sourceModificationTime - metadata.modificationTime) < 0.001,
              cache.bucketCount == bucketCount else { return nil }
        return cache.waveform
    }
}
