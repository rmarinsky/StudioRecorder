@preconcurrency import AVFoundation
import XCTest
@testable import StudioRecorder

final class ProjectAudioWaveformTests: XCTestCase {
    func testSilenceDetectorFindsRealAudioGapWithoutChangingSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appending(path: "gap.caf")
        try writeAudioWithGap(to: sourceURL)
        let rawBytes = try Data(contentsOf: sourceURL)
        let waveform = try await ProjectAudioWaveformAnalyzer().waveform(
            for: sourceURL,
            cacheURL: directory.appending(path: "analysis/silence-waveform.json"),
            bucketCount: 100
        )
        let timeline = try ProjectEditTimeline(trackID: "program", sourceDuration: waveform.duration)

        let candidates = ProjectSilenceDetector.candidates(in: waveform, timeline: timeline)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].lowerBound, 0.58, accuracy: 0.05)
        XCTAssertEqual(candidates[0].upperBound, 1.17, accuracy: 0.05)
        XCTAssertEqual(try Data(contentsOf: sourceURL), rawBytes)
    }

    func testSilenceCandidatesFollowReorderedOutputAndSkipShortQuietGaps() throws {
        let buckets = (0..<20).map { index in
            ProjectAudioWaveformBucket(
                sourceStart: Double(index) * 0.1, duration: 0.1,
                peak: (10...14).contains(index) || (3...4).contains(index) ? 0.005 : 0.4,
                rms: (10...14).contains(index) || (3...4).contains(index) ? 0.003 : 0.2,
                isClipped: false
            )
        }
        let waveform = ProjectAudioWaveform(duration: 2, buckets: buckets)
        var timeline = try ProjectEditTimeline(trackID: "screen", sourceDuration: 2)
        try timeline.split(at: 1)
        try timeline.move(segmentID: timeline.segments[0].id, toIndex: 1)

        let candidates = ProjectSilenceDetector.candidates(
            in: waveform, timeline: timeline,
            minimumDuration: 0.35, padding: 0
        )

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].lowerBound, 0, accuracy: 0.001)
        XCTAssertEqual(candidates[0].upperBound, 0.5, accuracy: 0.001)
    }

    @MainActor
    func testEditSessionLoadsWaveformWithoutBlockingProjectLoad() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appending(path: "program.caf")
        try writeAudioFile(to: sourceURL)
        let projectID = UUID()
        let track = RecordingTrackDescriptor(
            id: "program",
            kind: .program,
            displayID: nil,
            relativePath: sourceURL.lastPathComponent
        )
        let session = ProjectEditSession()

        await session.load(
            projectID: projectID,
            projectRootURL: directory,
            track: track,
            sourceURL: sourceURL,
            programSources: nil,
            initialPresentation: .default
        )

        XCTAssertNotNil(session.timeline)
        let deadline = ContinuousClock.now + .seconds(2)
        while session.audioWaveform == nil,
              session.audioWaveformError == nil,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(session.audioWaveform?.buckets.count, 180)
        XCTAssertNil(session.audioWaveformError)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appending(path: "analysis/audio-waveform.json").path
        ))
        session.stop()
    }

    func testAnalyzerBuildsSourceTimeBucketsMarksClippingAndWritesAReusableCache() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appending(path: "levels.caf")
        let cacheURL = directory.appending(path: "analysis/waveform.json")
        try writeAudioFile(to: sourceURL)
        let rawBytes = try Data(contentsOf: sourceURL)
        let analyzer = ProjectAudioWaveformAnalyzer()

        let waveform = try await analyzer.waveform(
            for: sourceURL,
            cacheURL: cacheURL,
            bucketCount: 2
        )

        XCTAssertEqual(waveform.buckets.count, 2)
        XCTAssertEqual(waveform.duration, 1, accuracy: 0.01)
        XCTAssertEqual(waveform.buckets[0].sourceStart, 0, accuracy: 0.001)
        XCTAssertEqual(waveform.buckets[0].duration, 0.5, accuracy: 0.01)
        XCTAssertEqual(waveform.buckets[1].sourceStart, 0.5, accuracy: 0.01)
        XCTAssertEqual(waveform.buckets[1].duration, 0.5, accuracy: 0.01)
        XCTAssertLessThan(waveform.buckets[0].peak, 0.3)
        XCTAssertFalse(waveform.buckets[0].isClipped)
        XCTAssertGreaterThan(waveform.buckets[1].peak, 0.99)
        XCTAssertTrue(waveform.buckets[1].isClipped)
        XCTAssertEqual(waveform.clippedRegionCount, 1)
        XCTAssertGreaterThan(waveform.buckets[0].rms, waveform.buckets[1].rms)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
        let cached = try await analyzer.waveform(for: sourceURL, cacheURL: cacheURL, bucketCount: 2)
        XCTAssertEqual(cached, waveform)
        XCTAssertEqual(try Data(contentsOf: sourceURL), rawBytes)
    }

    func testAnalyzerReturnsDecodedWaveformWhenDerivedCacheCannotBeWritten() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appending(path: "levels.caf")
        try writeAudioFile(to: sourceURL)

        let waveform = try await ProjectAudioWaveformAnalyzer().waveform(
            for: sourceURL,
            cacheURL: sourceURL.appending(path: "impossible/waveform.json"),
            bucketCount: 2
        )

        XCTAssertEqual(waveform.buckets.count, 2)
        XCTAssertEqual(waveform.clippedRegionCount, 1)
    }

    func testAnalyzerBuildsIndependentWaveformsForEachStemTrack() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let quietURL = directory.appending(path: "quiet.caf")
        let loudURL = directory.appending(path: "loud.caf")
        let stemsURL = directory.appending(path: "stems.mov")
        try writeConstantAudioFile(to: quietURL, amplitude: 0.1)
        try writeConstantAudioFile(to: loudURL, amplitude: 0.8)
        try await combineAudioTracks([quietURL, loudURL], to: stemsURL)
        let analyzer = ProjectAudioWaveformAnalyzer()
        let stemTracks = try await AVURLAsset(url: stemsURL).loadTracks(withMediaType: .audio)
        XCTAssertEqual(stemTracks.count, 2)

        let quiet = try await analyzer.waveform(
            for: stemsURL,
            cacheURL: directory.appending(path: "quiet.json"),
            bucketCount: 2,
            persistentTrackID: stemTracks[0].trackID
        )
        let loud = try await analyzer.waveform(
            for: stemsURL,
            cacheURL: directory.appending(path: "loud.json"),
            bucketCount: 2,
            persistentTrackID: stemTracks[1].trackID
        )

        XCTAssertLessThan(quiet.buckets[0].peak, 0.2)
        XCTAssertGreaterThan(loud.buckets[0].peak, 0.7)
    }

    private func writeAudioFile(to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<48_000 {
            samples[frame] = frame < 24_000
                ? sin(Float(frame) * 0.04) * 0.25
                : sin(Float(frame) * 0.04) * 0.08
        }
        samples[36_000] = 1
        try file.write(from: buffer)
    }

    private func writeAudioWithGap(to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
        buffer.frameLength = 96_000
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<96_000 {
            samples[frame] = frame < 24_000 || frame >= 60_000
                ? sin(Float(frame) * 0.04) * 0.3
                : 0
        }
        try file.write(from: buffer)
    }

    private func writeConstantAudioFile(to url: URL, amplitude: Float) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<4_800 { samples[frame] = sin(Float(frame) * 0.04) * amplitude }
        try file.write(from: buffer)
    }

    private func combineAudioTracks(_ sources: [URL], to destination: URL) async throws {
        let composition = AVMutableComposition()
        for source in sources {
            let asset = AVURLAsset(url: source)
            let sourceTracks = try await asset.loadTracks(withMediaType: .audio)
            let sourceTrack = try XCTUnwrap(sourceTracks.first)
            let track = try XCTUnwrap(
                composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
            )
            let range = try await sourceTrack.load(.timeRange)
            try track.insertTimeRange(range, of: sourceTrack, at: .zero)
        }
        let export = try XCTUnwrap(
            AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)
        )
        try await export.export(to: destination, as: .mov)
    }
}
