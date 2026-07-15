@preconcurrency import AVFoundation
import XCTest
@testable import StudioRecorder

final class ProjectAudioWaveformTests: XCTestCase {
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
}
