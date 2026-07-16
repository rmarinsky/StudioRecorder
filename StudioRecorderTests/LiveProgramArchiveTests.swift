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

    func testMovieWriterKeepsSystemAndMonoMicrophoneAsSeparateAudioTracks() async throws {
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
        try await writer.appendAudio(
            SendableSampleBuffer(value: try audioSampleBuffer(sampleRate: 48_000, channels: 2)),
            track: 0
        )
        try await writer.appendAudio(
            SendableSampleBuffer(value: try audioSampleBuffer(sampleRate: 44_100, channels: 1)),
            track: 1
        )
        try await writer.appendVideo(SendableSampleBuffer(value: try videoSampleBuffer(frame: 1)))
        _ = try await writer.finish()

        let asset = AVURLAsset(url: outputURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 2)
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
        size: CGSize = CGSize(width: 320, height: 180)
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
            presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: 30),
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
        presentationTime: CMTime = .zero
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
