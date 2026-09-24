import XCTest
@testable import StudioRecorder

final class ProjectEditTimelineTests: XCTestCase {
    func testPauseTimelineCompactsMultiplePausedRangesWithoutTouchingSourceTime() throws {
        var pauses = RecordingPauseTimeline()
        XCTAssertTrue(pauses.pause(at: 103))
        XCTAssertTrue(pauses.resume(at: 105))
        XCTAssertTrue(pauses.pause(at: 108))
        XCTAssertTrue(pauses.resume(at: 110))

        let timeline = try pauses.makeEditTimeline(
            trackID: "screen-7",
            recordingStartedAt: 100,
            stoppedAt: 112,
            sourceDuration: 12,
            segmentIDs: [
                UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            ]
        )

        XCTAssertEqual(timeline.duration, 8, accuracy: 0.001)
        XCTAssertEqual(
            timeline.segments,
            [
                ProjectEditSegment(
                    id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                    sourceStart: 0,
                    duration: 3
                ),
                ProjectEditSegment(
                    id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                    sourceStart: 5,
                    duration: 3
                ),
                ProjectEditSegment(
                    id: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
                    sourceStart: 10,
                    duration: 2
                ),
            ]
        )
        XCTAssertEqual(try XCTUnwrap(timeline.sourceTime(at: 3)), 5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(timeline.sourceTime(at: 6)), 10, accuracy: 0.001)
    }

    func testEditedPlaybackTimeMapsBackToRecordedCursorTime() throws {
        var timeline = try ProjectEditTimeline(trackID: "screen-7", sourceDuration: 10)
        try timeline.trimStart(to: 3)

        XCTAssertEqual(try XCTUnwrap(timeline.sourceTime(at: 0)), 3, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(timeline.sourceTime(at: 2)), 5, accuracy: 0.001)
    }

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

    func testDeletingArbitraryOutputRangeCutsAcrossSegmentsAndPreservesSourceMedia() throws {
        var timeline = try ProjectEditTimeline(trackID: "screen-3", sourceDuration: 12)
        try timeline.split(at: 5)
        try timeline.split(at: 8)

        try timeline.delete(range: 3..<9)

        XCTAssertEqual(timeline.duration, 6, accuracy: 0.001)
        XCTAssertEqual(timeline.segments.map(\.sourceStart), [0, 9])
        XCTAssertEqual(timeline.segments.map(\.duration), [3, 3])
        XCTAssertEqual(try XCTUnwrap(timeline.sourceTime(at: 3)), 9, accuracy: 0.001)
        XCTAssertEqual(timeline.sourceDuration, 12, accuracy: 0.001)
    }

    func testDeletingEntireOutputIsRejectedWithoutChangingTheTimeline() throws {
        var timeline = try ProjectEditTimeline(trackID: "screen-3", sourceDuration: 12)
        let original = timeline

        XCTAssertThrowsError(try timeline.delete(range: 0..<12))
        XCTAssertEqual(timeline, original)
    }

    func testDeletingWithinOneSegmentKeepsDistinctPiecesAndRejectsInvalidBounds() throws {
        var timeline = try ProjectEditTimeline(trackID: "screen-3", sourceDuration: 12)
        try timeline.delete(range: 3..<5)

        XCTAssertEqual(timeline.segments.map(\.sourceStart), [0, 5])
        XCTAssertEqual(timeline.segments.map(\.duration), [3, 7])
        XCTAssertNotEqual(timeline.segments[0].id, timeline.segments[1].id)

        let saved = timeline
        XCTAssertThrowsError(try timeline.delete(range: 9..<11))
        XCTAssertEqual(timeline, saved)
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
        let rawSceneURL = rootURL.appending(path: "scene/layout.json")
        try FileManager.default.createDirectory(
            at: rawSceneURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let originalSceneBytes = Data("captured-scene-must-not-change".utf8)
        try originalSceneBytes.write(to: rawSceneURL)

        var timeline = try ProjectEditTimeline(trackID: "screen-3", sourceDuration: 12)
        try timeline.split(at: 5)
        var presentation = CapturePresentationSnapshot.default
        presentation.canvas = CaptureCanvasSnapshot(preset: .verticalHD)
        presentation.camera.centerX = 0.25
        var sceneTimeline = StudioSceneTimeline(initialPresentation: presentation)
        var zoomed = presentation
        zoomed.framing = ScreenFramingSnapshot(mode: .fixedRegion, scale: 0.5)
        sceneTimeline.append(zoomed, at: 2, kind: .manualZoomStart)
        let document = ProjectEditDocument(
            projectID: projectID,
            updatedAt: Date(timeIntervalSinceReferenceDate: 42),
            timelines: [timeline],
            presentation: presentation,
            privacyOverlays: [
                ProjectPrivacyOverlay(
                    sourceStart: 2,
                    duration: 3,
                    centerX: 0.5,
                    centerY: 0.25,
                    width: 0.4,
                    height: 0.2,
                    style: .blur
                )
            ],
            sceneTimeline: sceneTimeline,
            audioAdjustment: ProjectAudioAdjustment(gain: 0.45)
        )
        let store = ProjectEditStore()

        try await store.save(document, in: rootURL)
        let reloaded = try await store.load(from: rootURL, expectedProjectID: projectID)

        XCTAssertEqual(reloaded, document)
        XCTAssertEqual(try Data(contentsOf: rawTrackURL), originalRawBytes)
        XCTAssertEqual(try Data(contentsOf: rawSceneURL), originalSceneBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.appending(path: "edit.json").path))
    }

    func testLegacyEditWithoutPresentationStillDecodes() throws {
        let projectID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let data = Data(
            """
            {"schemaVersion":1,"projectID":"\(projectID.uuidString)","updatedAt":"2026-07-15T12:00:00Z","timelines":[]}
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let document = try decoder.decode(ProjectEditDocument.self, from: data)

        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertNil(document.presentation)
        XCTAssertTrue(document.privacyOverlays.isEmpty)
    }

    func testPrivacyOverlayValidationKeepsTimingAndRegionInsideTheSourceAndCanvas() {
        let overlay = ProjectPrivacyOverlay(
            sourceStart: 20,
            duration: 5,
            centerX: 0,
            centerY: 1,
            width: 0.4,
            height: 0.2
        ).validated(sourceDuration: 10)

        XCTAssertEqual(overlay.sourceStart, 9.95, accuracy: 0.001)
        XCTAssertEqual(overlay.duration, 0.05, accuracy: 0.001)
        XCTAssertEqual(overlay.centerX, 0.2, accuracy: 0.001)
        XCTAssertEqual(overlay.centerY, 0.9, accuracy: 0.001)
        XCTAssertTrue(overlay.isActive(at: 9.975))
        XCTAssertFalse(overlay.isActive(at: 10))

        let undersized = ProjectPrivacyOverlay(sourceStart: 0, duration: 1, width: 0.01)
        XCTAssertFalse(undersized.isPersistable)
        XCTAssertEqual(
            undersized.validated(sourceDuration: 10).width,
            ProjectPrivacyOverlay.minimumDimension,
            accuracy: 0.001
        )
        XCTAssertEqual(ProjectPrivacyOverlay(sourceStart: 0, duration: 1).style, .solid)
    }

    func testVersionTwoDocumentDecodesWithoutPrivacyOverlays() throws {
        let projectID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let data = Data(
            """
            {"schemaVersion":2,"projectID":"\(projectID.uuidString)","updatedAt":"2026-07-15T12:00:00Z","timelines":[],"presentation":null}
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let document = try decoder.decode(ProjectEditDocument.self, from: data)

        XCTAssertEqual(document.schemaVersion, 2)
        XCTAssertTrue(document.privacyOverlays.isEmpty)
    }

    func testVersionThreeDocumentDecodesWithoutASceneTimelineOverride() throws {
        let projectID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let data = Data(
            """
            {"schemaVersion":3,"projectID":"\(projectID.uuidString)","updatedAt":"2026-07-15T12:00:00Z","timelines":[],"presentation":null,"privacyOverlays":[]}
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let document = try decoder.decode(ProjectEditDocument.self, from: data)

        XCTAssertEqual(document.schemaVersion, 3)
        XCTAssertNil(document.sceneTimeline)
    }

    func testLegacyEditDefaultsToUnchangedAudioAndCurrentEditPersistsAdjustment() async throws {
        let projectID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let legacyData = Data(
            """
            {"schemaVersion":4,"projectID":"\(projectID.uuidString)","updatedAt":"2026-07-15T12:00:00Z","timelines":[],"presentation":null,"privacyOverlays":[],"sceneTimeline":null}
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let legacy = try decoder.decode(ProjectEditDocument.self, from: legacyData)

        XCTAssertEqual(legacy.audioAdjustment, .unchanged)

        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).recordingproject", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        var current = ProjectEditDocument(projectID: projectID, timelines: [])
        current.replaceAudioAdjustment(ProjectAudioAdjustment(gain: 0.35, isMuted: true))

        try await ProjectEditStore().save(current, in: rootURL)
        let loaded = try await ProjectEditStore().load(from: rootURL, expectedProjectID: projectID)
        let reloaded = try XCTUnwrap(loaded)

        XCTAssertEqual(reloaded.audioAdjustment.gain, 0.35, accuracy: 0.001)
        XCTAssertEqual(reloaded.audioAdjustment.isMuted, true)
        XCTAssertEqual(reloaded.audioAdjustment.effectiveGain, 0)
    }

    func testCurrentEditPersistsValidatedSegmentAudioAdjustment() async throws {
        let projectID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        var timeline = try ProjectEditTimeline(
            trackID: "program",
            sourceDuration: 2,
            initialSegmentID: firstID
        )
        try timeline.split(at: 1, newSegmentID: secondID)
        var document = ProjectEditDocument(projectID: projectID, timelines: [timeline])
        document.replaceSegmentAudioAdjustment(
            ProjectSegmentAudioAdjustment(segmentID: secondID, gain: 0.4, isMuted: true)
        )
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "\(projectID.uuidString).recordingproject", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let store = ProjectEditStore()
        try await store.save(document, in: rootURL)
        let loaded = try await store.load(from: rootURL, expectedProjectID: projectID)
        let reloaded = try XCTUnwrap(loaded)

        XCTAssertEqual(reloaded.schemaVersion, ProjectEditDocument.currentSchemaVersion)
        XCTAssertEqual(reloaded.segmentAudioAdjustment(for: firstID).effectiveGain, 1)
        XCTAssertEqual(reloaded.segmentAudioAdjustment(for: secondID).effectiveGain, 0)
    }

    func testCurrentEditPersistsIndependentSourceAudioAdjustments() async throws {
        let projectID = UUID()
        var document = ProjectEditDocument(projectID: projectID, timelines: [])
        document.replaceSourceAudioAdjustment(
            ProjectAudioSourceAdjustment(source: .systemAudio, gain: 0.4)
        )
        document.replaceSourceAudioAdjustment(
            ProjectAudioSourceAdjustment(source: .microphone, isMuted: true)
        )
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "\(projectID.uuidString).recordingproject", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let store = ProjectEditStore()
        try await store.save(document, in: rootURL)
        let stored = try await store.load(from: rootURL, expectedProjectID: projectID)
        let loaded = try XCTUnwrap(stored)

        XCTAssertEqual(loaded.schemaVersion, 7)
        XCTAssertEqual(loaded.sourceAudioAdjustment(for: .systemAudio).gain, 0.4, accuracy: 0.001)
        XCTAssertEqual(loaded.sourceAudioAdjustment(for: .microphone).effectiveGain, 0)
    }

    func testEditStoreRejectsDuplicateSegmentIDsAcrossTimelines() async throws {
        let projectID = UUID()
        let duplicateID = UUID()
        let document = ProjectEditDocument(
            projectID: projectID,
            timelines: [
                try ProjectEditTimeline(trackID: "screen-1", sourceDuration: 1, initialSegmentID: duplicateID),
                try ProjectEditTimeline(trackID: "screen-2", sourceDuration: 1, initialSegmentID: duplicateID),
            ],
            segmentAudioAdjustments: [
                ProjectSegmentAudioAdjustment(segmentID: duplicateID, gain: 0.5),
            ]
        )
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "\(projectID.uuidString).recordingproject", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        do {
            try await ProjectEditStore().save(document, in: rootURL)
            XCTFail("Segment IDs must identify exactly one timeline segment.")
        } catch {
            XCTAssertEqual(error as? ProjectEditStoreError, .invalidSegmentAudioAdjustment)
        }
    }

    func testEditStoreRejectsAnOutOfRangeAudioAdjustment() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).recordingproject", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let projectID = UUID()
        var document = ProjectEditDocument(projectID: projectID, timelines: [])
        document.audioAdjustment.gain = 1.5

        do {
            try await ProjectEditStore().save(document, in: rootURL)
            XCTFail("An out-of-range audio adjustment must not cross the edit-document trust boundary.")
        } catch {
            XCTAssertEqual(error as? ProjectEditStoreError, .invalidAudioAdjustment)
        }

        let corruptData = Data(
            """
            {"schemaVersion":5,"projectID":"\(projectID.uuidString)","updatedAt":"2026-07-16T00:00:00Z","timelines":[],"presentation":null,"privacyOverlays":[],"sceneTimeline":null,"audioAdjustment":{"gain":1.5,"isMuted":false}}
            """.utf8
        )
        try corruptData.write(to: rootURL.appending(path: ProjectEditStore.filename))
        do {
            _ = try await ProjectEditStore().load(from: rootURL, expectedProjectID: projectID)
            XCTFail("Corrupt persisted audio gain must not be silently clamped.")
        } catch {
            XCTAssertEqual(error as? ProjectEditStoreError, .invalidAudioAdjustment)
        }
    }

    func testEditStoreMigratesLegacyDocumentToCurrentSchema() async throws {
        let projectID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "\(projectID.uuidString).recordingproject", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let legacyData = Data(
            """
            {"schemaVersion":1,"projectID":"\(projectID.uuidString)","updatedAt":"2026-07-15T12:00:00Z","timelines":[]}
            """.utf8
        )
        try legacyData.write(to: rootURL.appending(path: ProjectEditStore.filename))

        let migrated = try await ProjectEditStore().load(from: rootURL, expectedProjectID: projectID)

        XCTAssertEqual(migrated?.schemaVersion, ProjectEditDocument.currentSchemaVersion)
        XCTAssertNil(migrated?.presentation)
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
