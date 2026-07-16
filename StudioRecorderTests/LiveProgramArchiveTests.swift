@preconcurrency import AVFoundation
import XCTest
@testable import StudioRecorder

@MainActor
final class LiveProgramArchiveTests: XCTestCase {
    func testRecordingAudioStemWriterKeepsTwoSourcesOnTheScreenTimeline() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "RecordingAudioStemWriterTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appending(path: "audio-stems.mov")
        let writer = try RecordingAudioStemWriter(configuration: .init(
            outputURL: outputURL,
            capturesSystemAudio: true,
            capturesMicrophone: true
        ))

        XCTAssertTrue(try writer.establishTimeline(at: CMTime(seconds: 10, preferredTimescale: 48_000)))
        try writer.append(
            try audioSampleBuffer(
                sampleRate: 48_000,
                channels: 2,
                presentationTime: CMTime(seconds: 10.1, preferredTimescale: 48_000)
            ),
            source: .systemAudio
        )
        try writer.append(
            try audioSampleBuffer(
                sampleRate: 44_100,
                channels: 1,
                presentationTime: CMTime(seconds: 10.35, preferredTimescale: 44_100)
            ),
            source: .microphone
        )

        let result = try await writer.finish()

        XCTAssertEqual(result.outputURL, outputURL)
        XCTAssertEqual(result.sampleCounts[.systemAudio], 1)
        XCTAssertEqual(result.sampleCounts[.microphone], 1)
        let asset = AVURLAsset(url: outputURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(
            Set(result.persistentTrackIDs.values),
            Set(tracks.map(\.trackID))
        )
        for track in tracks {
            let metadata = try await track.load(.metadata)
            let marker = try await AVMetadataItem.metadataItems(
                from: metadata,
                filteredByIdentifier: .quickTimeMetadataDisplayName
            ).first?.load(.stringValue)
            let markerValue = try XCTUnwrap(marker)
            let source = try XCTUnwrap(RecordingAudioStemSource(
                rawValue: String(markerValue.dropFirst(RecordingAudioStemWriter.sourceMetadataPrefix.count))
            ))
            XCTAssertTrue(markerValue.hasPrefix(RecordingAudioStemWriter.sourceMetadataPrefix))
            XCTAssertEqual(result.persistentTrackIDs[source], track.trackID)
        }
        var durations: [TimeInterval] = []
        for track in tracks {
            durations.append(try await track.load(.timeRange).duration.seconds)
        }
        durations.sort()
        XCTAssertEqual(durations[1] - durations[0], 0.25, accuracy: 0.03)
    }

    func testRecordingAudioStemWriterPreservesQuietRequestedSources() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "RecordingAudioStemWriterTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appending(path: "audio-stems.mov")
        let writer = try RecordingAudioStemWriter(configuration: .init(
            outputURL: outputURL,
            capturesSystemAudio: true,
            capturesMicrophone: true
        ))

        XCTAssertTrue(try writer.establishTimeline(at: CMTime(seconds: 10, preferredTimescale: 48_000)))
        let result = try await writer.finish()

        XCTAssertEqual(result.sampleCounts[.systemAudio], 0)
        XCTAssertEqual(result.sampleCounts[.microphone], 0)
        let tracks = try await AVURLAsset(url: outputURL).loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 2)
    }

    func testRecordingAudioStemWriterAcceptsFirstAudioAfterThirtySeconds() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "RecordingAudioStemWriterTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appending(path: "audio-stems.mov")
        let writer = try RecordingAudioStemWriter(configuration: .init(
            outputURL: outputURL,
            capturesSystemAudio: true,
            capturesMicrophone: false
        ))

        XCTAssertTrue(try writer.establishTimeline(at: CMTime(seconds: 10, preferredTimescale: 48_000)))
        try writer.append(
            try audioSampleBuffer(
                sampleRate: 48_000,
                channels: 2,
                presentationTime: CMTime(seconds: 50.5, preferredTimescale: 48_000)
            ),
            source: .systemAudio
        )
        let result = try await writer.finish()

        XCTAssertEqual(result.sampleCounts[.systemAudio], 1)
        let tracks = try await AVURLAsset(url: outputURL).loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let timeRange = try await track.load(.timeRange)
        XCTAssertGreaterThan(timeRange.duration.seconds, 40)
    }

    func testMovieWriterFinalizesPlayableFragmentedComposedVideo() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LiveProgramArchiveTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appending(path: "program.mov")
        let writer = try LiveProgramMovieWriter(configuration: .init(
            outputURL: outputURL,
            canvasSize: CGSize(width: 320, height: 180),
            frameRate: 30,
            videoBitRate: 1_000_000,
            capturesSystemAudio: false,
            capturesMicrophone: false
        ))

        for frame in 0..<3 {
            try await writer.appendVideo(SendableSampleBuffer(
                value: try videoSampleBuffer(frame: frame)
            ))
        }
        let resultURL = try await writer.finish()

        XCTAssertEqual(resultURL, outputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let asset = AVURLAsset(url: outputURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertGreaterThan(duration.seconds, 0)
    }

    func testMovieWriterFinalizesPortraitAnd4KCanvasDimensions() async throws {
        for size in [CGSize(width: 1_080, height: 1_920), CGSize(width: 3_840, height: 2_160)] {
            let directory = FileManager.default.temporaryDirectory.appending(
                path: "LiveProgramArchiveTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let outputURL = directory.appending(path: "program.mov")
            let writer = try LiveProgramMovieWriter(configuration: .init(
                outputURL: outputURL,
                canvasSize: size,
                frameRate: 30,
                videoBitRate: 12_000_000,
                capturesSystemAudio: false,
                capturesMicrophone: false
            ))

            for frame in 0..<2 {
                try await writer.appendVideo(SendableSampleBuffer(
                    value: try videoSampleBuffer(frame: frame, size: size)
                ))
            }
            _ = try await writer.finish()

            let asset = AVURLAsset(url: outputURL)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let naturalSize = try await track.load(.naturalSize)
            XCTAssertEqual(naturalSize.width, size.width)
            XCTAssertEqual(naturalSize.height, size.height)
        }
    }

    func testMovieWriterFlattensSystemAndMonoMicrophoneIntoOnePlayableTrack() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "LiveProgramArchiveTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appending(path: "program.mov")
        let writer = try LiveProgramMovieWriter(configuration: .init(
            outputURL: outputURL,
            canvasSize: CGSize(width: 320, height: 180),
            frameRate: 30,
            videoBitRate: 1_000_000,
            capturesSystemAudio: true,
            capturesMicrophone: true
        ))

        let liveStart = CMTime(seconds: 10, preferredTimescale: 600)
        for frame in 0..<7 {
            try await writer.appendVideo(SendableSampleBuffer(
                value: try videoSampleBuffer(frame: frame, presentationTimeOffset: liveStart)
            ))
        }
        try await writer.appendAudio(
            SendableSampleBuffer(value: try audioSampleBuffer(
                sampleRate: 48_000,
                channels: 2,
                frameCount: 9_600,
                presentationTime: liveStart,
                toneFrequency: 440,
                activeChannels: [0]
            )),
            track: 0
        )
        try await writer.appendAudio(
            SendableSampleBuffer(value: try audioSampleBuffer(
                sampleRate: 44_100,
                channels: 1,
                frameCount: 4_410,
                presentationTime: CMTimeAdd(
                    liveStart,
                    CMTime(seconds: 0.1, preferredTimescale: 44_100)
                ),
                toneFrequency: 880,
                activeChannels: [0]
            )),
            track: 1
        )
        _ = try await writer.finish()

        let asset = AVURLAsset(url: outputURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
        let formatDescriptions = try await audioTracks[0].load(.formatDescriptions)
        let description = try XCTUnwrap(formatDescriptions.first)
        let streamDescription = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(description))
        XCTAssertEqual(streamDescription.pointee.mSampleRate, 48_000)
        XCTAssertEqual(streamDescription.pointee.mChannelsPerFrame, 2)
        let duration = try await asset.load(.duration).seconds
        XCTAssertLessThan(duration, 1)

        let decoded = try decodedAudio(at: outputURL)
        XCTAssertEqual(decoded.channels.count, 2)
        XCTAssertGreaterThan(spectralMagnitude(decoded.channels[0], sampleRate: decoded.sampleRate, frequency: 440), 0.01)
        XCTAssertGreaterThan(spectralMagnitude(decoded.channels[0], sampleRate: decoded.sampleRate, frequency: 880), 0.01)
        XCTAssertGreaterThan(spectralMagnitude(decoded.channels[1], sampleRate: decoded.sampleRate, frequency: 880), 0.01)
        let windowLength = min(Int(decoded.sampleRate * 0.06), decoded.channels[1].count / 3)
        let earlyMicrophone = Array(decoded.channels[1].prefix(windowLength))
        let lateMicrophone = Array(decoded.channels[1].suffix(windowLength))
        XCTAssertLessThan(
            spectralMagnitude(earlyMicrophone, sampleRate: decoded.sampleRate, frequency: 880),
            0.005
        )
        XCTAssertGreaterThan(
            spectralMagnitude(lateMicrophone, sampleRate: decoded.sampleRate, frequency: 880),
            0.01
        )

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let videoDescriptions = try await videoTrack.load(.formatDescriptions)
        XCTAssertEqual(
            videoDescriptions.first.map(CMFormatDescriptionGetMediaSubType),
            kCMVideoCodecType_H264
        )
        let samples = try compressedVideoSamples(asset: asset, track: videoTrack)
        XCTAssertGreaterThanOrEqual(samples.count, 7)
        XCTAssertEqual(samples.first?.presentationTimeStamp.seconds ?? -1, 0, accuracy: 0.001)
        XCTAssertGreaterThan(samples.last?.presentationTimeStamp.seconds ?? -1, 0)
        XCTAssertLessThanOrEqual(samples.last?.presentationTimeStamp.seconds ?? .infinity, duration)
    }

    func testMovieWriterPreservesAPlayableSilentTrackWhenRequestedAudioIsQuiet() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "LiveProgramArchiveTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appending(path: "program.mov")
        let writer = try LiveProgramMovieWriter(configuration: .init(
            outputURL: outputURL,
            canvasSize: CGSize(width: 320, height: 180),
            frameRate: 30,
            videoBitRate: 1_000_000,
            capturesSystemAudio: true,
            capturesMicrophone: true
        ))

        try await writer.appendVideo(SendableSampleBuffer(value: try videoSampleBuffer(frame: 0)))
        try await writer.appendVideo(SendableSampleBuffer(value: try videoSampleBuffer(frame: 1)))
        _ = try await writer.finish()

        let audioTracks = try await AVURLAsset(url: outputURL).loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
    }

    func testArchiveSessionFinalizesWriterAndCompletionExactlyOnce() async {
        let expectedURL = URL(filePath: "/tmp/program.mov")
        let writer = InspectableProgramMovieWriter(result: .success(expectedURL))
        let recorder = ArchiveCompletionRecorder()
        let session = LiveProgramArchiveSession(writer: writer) { result in
            recorder.append(result)
        }

        await session.finish()
        await session.finish()

        let finishCount = await writer.finishCount()
        XCTAssertEqual(finishCount, 1)
        XCTAssertEqual(recorder.urls, [expectedURL])
        XCTAssertTrue(recorder.failures.isEmpty)
    }

    func testArchiveSessionSurfacesAppendFailureWithoutTryingToFinalizeAgain() async throws {
        let failure = LiveProgramMovieWriterError.appendFailed("Synthetic writer failure.")
        let writer = InspectableProgramMovieWriter(result: .failure(failure), appendFailure: failure)
        let recorder = ArchiveCompletionRecorder()
        let session = LiveProgramArchiveSession(writer: writer) { result in
            recorder.append(result)
        }

        await session.appendVideo(SendableSampleBuffer(value: try videoSampleBuffer(frame: 0)))
        await session.finish()

        let finishCount = await writer.finishCount()
        let abortCount = await writer.abortCount()
        XCTAssertEqual(finishCount, 0)
        XCTAssertEqual(abortCount, 1)
        XCTAssertEqual(recorder.failures.count, 1)
        XCTAssertTrue(recorder.urls.isEmpty)
    }

    private func videoSampleBuffer(
        frame: Int,
        size: CGSize = CGSize(width: 320, height: 180),
        presentationTimeOffset: CMTime = .zero
    ) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: "LiveProgramArchiveTests", code: Int(status))
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(baseAddress, Int32(frame * 40), CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr,
        let formatDescription else {
            throw NSError(domain: "LiveProgramArchiveTests", code: 2)
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTimeAdd(
                presentationTimeOffset,
                CMTime(value: CMTimeValue(frame), timescale: 30)
            ),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr,
        let sampleBuffer else {
            throw NSError(domain: "LiveProgramArchiveTests", code: 3)
        }
        return sampleBuffer
    }

    private func audioSampleBuffer(
        sampleRate: Double,
        channels: AVAudioChannelCount,
        frameCount: AVAudioFrameCount = 1_024,
        presentationTime: CMTime = .zero,
        toneFrequency: Double? = nil,
        toneAmplitude: Float = 0.2,
        activeChannels: Set<Int> = []
    ) throws -> CMSampleBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ),
        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "LiveProgramArchiveTests", code: 4)
        }
        pcmBuffer.frameLength = frameCount
        if let toneFrequency, let channelData = pcmBuffer.floatChannelData {
            for channel in 0..<Int(channels) where activeChannels.isEmpty || activeChannels.contains(channel) {
                for frame in 0..<Int(frameCount) {
                    channelData[channel][frame] = toneAmplitude * Float(
                        sin(2 * Double.pi * toneFrequency * Double(frame) / sampleRate)
                    )
                }
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
            throw NSError(domain: "LiveProgramArchiveTests", code: 5)
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: presentationTime,
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
        let sampleBuffer else {
            throw NSError(domain: "LiveProgramArchiveTests", code: 6)
        }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            bufferList: pcmBuffer.audioBufferList
        ) == noErr else {
            throw NSError(domain: "LiveProgramArchiveTests", code: 7)
        }
        return sampleBuffer
    }

    private func decodedAudio(at url: URL) throws -> (sampleRate: Double, channels: [[Float]]) {
        let file = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frameCapacity = AVAudioFrameCount(max(file.length, 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: frameCapacity
        ))
        try file.read(into: buffer)
        let data = try XCTUnwrap(buffer.floatChannelData)
        let frameLength = Int(buffer.frameLength)
        let channels = (0..<Int(buffer.format.channelCount)).map { channel in
            Array(UnsafeBufferPointer(start: data[channel], count: frameLength))
        }
        return (buffer.format.sampleRate, channels)
    }

    private func spectralMagnitude(
        _ samples: [Float],
        sampleRate: Double,
        frequency: Double
    ) -> Double {
        guard !samples.isEmpty else { return 0 }
        var real = 0.0
        var imaginary = 0.0
        for (index, sample) in samples.enumerated() {
            let phase = 2 * Double.pi * frequency * Double(index) / sampleRate
            real += Double(sample) * cos(phase)
            imaginary -= Double(sample) * sin(phase)
        }
        return 2 * hypot(real, imaginary) / Double(samples.count)
    }

    private func compressedVideoSamples(
        asset: AVAsset,
        track: AVAssetTrack
    ) throws -> [CMSampleBuffer] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        try XCTSkipUnless(reader.canAdd(output), "Compressed video passthrough is unavailable.")
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var samples: [CMSampleBuffer] = []
        while let sample = output.copyNextSampleBuffer() {
            samples.append(sample)
        }
        XCTAssertEqual(reader.status, .completed)
        return samples
    }
}

private actor InspectableProgramMovieWriter: LiveProgramMovieWriting {
    private let result: Result<URL, Error>
    private let appendFailure: Error?
    private var finishes = 0
    private var aborts = 0

    init(result: Result<URL, Error>, appendFailure: Error? = nil) {
        self.result = result
        self.appendFailure = appendFailure
    }

    func appendVideo(_ sampleBuffer: SendableSampleBuffer) throws {
        if let appendFailure { throw appendFailure }
    }

    func appendAudio(_ sampleBuffer: SendableSampleBuffer, track: UInt8) throws {
        if let appendFailure { throw appendFailure }
    }

    func finish() throws -> URL {
        finishes += 1
        return try result.get()
    }

    func abort() {
        aborts += 1
    }

    func finishCount() -> Int { finishes }
    func abortCount() -> Int { aborts }
}

@MainActor
private final class ArchiveCompletionRecorder {
    private(set) var urls: [URL] = []
    private(set) var failures: [String] = []

    func append(_ result: Result<URL, LiveProgramArchiveFailure>) {
        switch result {
        case .success(let url): urls.append(url)
        case .failure(let failure): failures.append(failure.message)
        }
    }
}
