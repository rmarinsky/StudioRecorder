import XCTest
@testable import StudioRecorder

final class ProjectEditTimelineTests: XCTestCase {
    func testTimelineSupportsTrimSplitAndDeleteWithoutChangingSourceRanges() throws {
        let originalSegmentID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let splitSegmentID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        var timeline = try ProjectEditTimeline(
            trackID: "screen-3",
            sourceDuration: 12,
            initialSegmentID: originalSegmentID
        )

        try timeline.split(at: 5, newSegmentID: splitSegmentID)

        XCTAssertEqual(
            timeline.segments,
            [
                ProjectEditSegment(id: originalSegmentID, sourceStart: 0, duration: 5),
                ProjectEditSegment(id: splitSegmentID, sourceStart: 5, duration: 7),
            ]
        )

        try timeline.delete(segmentID: originalSegmentID)
        try timeline.trimStart(to: 1.5)
        try timeline.trimEnd(to: 4)

        XCTAssertEqual(timeline.duration, 4, accuracy: 0.001)
        XCTAssertEqual(
            timeline.segments,
            [ProjectEditSegment(id: splitSegmentID, sourceStart: 6.5, duration: 4)]
        )
        XCTAssertEqual(timeline.sourceDuration, 12, accuracy: 0.001)
    }

    func testEditStoreRoundTripsTheDocumentWithoutTouchingRawTracks() async throws {
        let projectID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "\(projectID.uuidString).recordingproject", directoryHint: .isDirectory)
        let rawTracksURL = rootURL.appending(path: "raw-tracks", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rawTracksURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let rawTrackURL = rawTracksURL.appending(path: "screen-3.mov")
        let originalRawBytes = Data("raw-track-must-not-change".utf8)
        try originalRawBytes.write(to: rawTrackURL)

        var timeline = try ProjectEditTimeline(trackID: "screen-3", sourceDuration: 12)
        try timeline.split(at: 5)
        let document = ProjectEditDocument(
            projectID: projectID,
            updatedAt: Date(timeIntervalSinceReferenceDate: 42),
            timelines: [timeline]
        )
        let store = ProjectEditStore()

        try await store.save(document, in: rootURL)
        let reloaded = try await store.load(from: rootURL, expectedProjectID: projectID)

        XCTAssertEqual(reloaded, document)
        XCTAssertEqual(try Data(contentsOf: rawTrackURL), originalRawBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.appending(path: "edit.json").path))
    }

    func testTrimEndAtAnExistingCutKeepsOnlyTheLeadingSegments() throws {
        let firstID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let secondID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        var timeline = try ProjectEditTimeline(trackID: "screen-3", sourceDuration: 12, initialSegmentID: firstID)
        try timeline.split(at: 5, newSegmentID: secondID)

        try timeline.trimEnd(to: 5)

        XCTAssertEqual(timeline.segments, [ProjectEditSegment(id: firstID, sourceStart: 0, duration: 5)])
    }
}
