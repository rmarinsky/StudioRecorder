import CoreMedia
import XCTest
@testable import StudioRecorder

@MainActor
final class StudioSceneTests: XCTestCase {
    func testSceneSwitchQueueChangesPresentationOnTheFirstEligibleFrame() {
        var wide = CapturePresentationSnapshot.default
        wide.name = "Wide"
        var speaker = wide
        speaker.name = "Speaker"
        speaker.camera.width = 0.42
        var queue = StudioSceneSwitchResolver(initialPresentation: wide)
        queue.schedule(StudioSceneSwitchEvent(
            sequence: 1,
            hostTime: 2_000,
            presentation: speaker,
            kind: .scene
        ))

        XCTAssertEqual(queue.resolve(forFrameHostTime: 1_999), wide.validated())
        XCTAssertEqual(queue.resolve(forFrameHostTime: 2_000), speaker.validated())
        XCTAssertEqual(queue.resolve(forFrameHostTime: 2_001), speaker.validated())
    }

    func testSceneSwitchQueueOrdersEventsByDisplayTimeInsteadOfDeliveryOrder() {
        var first = CapturePresentationSnapshot.default
        first.name = "First"
        var second = first
        second.name = "Second"
        var third = second
        third.name = "Third"
        var queue = StudioSceneSwitchResolver(initialPresentation: first)
        queue.schedule(StudioSceneSwitchEvent(
            sequence: 2,
            hostTime: 300,
            presentation: third,
            kind: .scene
        ))
        queue.schedule(StudioSceneSwitchEvent(
            sequence: 1,
            hostTime: 200,
            presentation: second,
            kind: .scene
        ))

        XCTAssertEqual(queue.resolve(forFrameHostTime: 250), second.validated())
        XCTAssertEqual(queue.resolve(forFrameHostTime: 300), third.validated())
    }

    func testSceneSwitchQueueUsesSequenceForEventsAtTheSameDisplayTime() {
        var first = CapturePresentationSnapshot.default
        first.name = "First"
        var second = first
        second.name = "Second"
        var third = second
        third.name = "Third"
        var queue = StudioSceneSwitchResolver(initialPresentation: first)
        queue.schedule(StudioSceneSwitchEvent(
            sequence: 2,
            hostTime: 300,
            presentation: third,
            kind: .scene
        ))
        queue.schedule(StudioSceneSwitchEvent(
            sequence: 1,
            hostTime: 300,
            presentation: second,
            kind: .scene
        ))

        XCTAssertEqual(queue.resolve(forFrameHostTime: 300), third.validated())
    }

    func testSceneSwitchEventMapsTheSharedBoundaryIntoRecordingSourceTime() {
        let start = CMClockConvertHostTimeToSystemUnits(CMTime(seconds: 40, preferredTimescale: 1_000_000))
        let end = CMClockConvertHostTimeToSystemUnits(CMTime(seconds: 42.75, preferredTimescale: 1_000_000))
        let event = StudioSceneSwitchEvent(
            sequence: 1,
            hostTime: end,
            presentation: .default,
            kind: .scene
        )

        XCTAssertEqual(event.sourceTime(since: start), 2.75, accuracy: 0.001)
        XCTAssertEqual(event.sourceTime(since: end + 1), 0, accuracy: 0.001)
    }

    func testSceneDetectsUnsavedLayoutChangesAfterValidation() {
        let scene = StudioScenePreset(presentation: .default)
        XCTAssertFalse(scene.isModified(comparedTo: .default))
        XCTAssertFalse(scene.isModified(comparedTo: nil))

        var changed = CapturePresentationSnapshot.default
        changed.camera.width = 0.42
        XCTAssertTrue(scene.isModified(comparedTo: changed))
    }

    func testLibraryPersistsNamedScenesAndReplacesAnExistingScene() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "StudioSceneTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "scenes.json")

        var presentation = CapturePresentationSnapshot.default
        presentation.name = "Interview"
        let scene = StudioScenePreset(presentation: presentation)
        let store = StudioSceneLibraryStore(fileURL: url)
        try store.save(scene)

        var updated = scene
        updated.presentation.camera.shape = .roundedRectangle
        try store.save(updated)

        let reloaded = StudioSceneLibraryStore(fileURL: url)
        XCTAssertEqual(reloaded.scenes, [updated])
        XCTAssertEqual(reloaded.scenes.first?.name, "Interview")
    }

    func testUnreadableLibraryIsPreservedInsteadOfSilentlyOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "StudioSceneTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "scenes.json")
        let original = Data("not-json".utf8)
        try original.write(to: url)
        let store = StudioSceneLibraryStore(fileURL: url)

        XCTAssertThrowsError(try store.save(StudioScenePreset(presentation: .default))) { error in
            XCTAssertEqual(error as? StudioSceneLibraryError, .unreadableExistingLibrary)
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testTimelineReturnsThePresentationActiveAtTheSourceTime() {
        var first = CapturePresentationSnapshot.default
        first.name = "Wide"
        var second = first
        second.name = "Speaker"
        second.camera.width = 0.42

        var timeline = StudioSceneTimeline(initialPresentation: first)
        timeline.append(second, at: 4.25)

        XCTAssertEqual(timeline.presentation(at: 4.24), first.validated())
        XCTAssertEqual(timeline.presentation(at: 4.25), second.validated())
        XCTAssertEqual(timeline.presentation(at: 99), second.validated())
    }

    func testTimelineRebasesSwitchesWhenTheAuthoritativeRecordingStartArrives() {
        var first = CapturePresentationSnapshot.default
        first.name = "Wide"
        var second = first
        second.name = "Speaker"

        var timeline = StudioSceneTimeline(initialPresentation: first)
        timeline.append(second, at: 0.25)
        timeline.offsetSceneSwitches(by: 1.5)

        XCTAssertEqual(timeline.presentation(at: 0), first.validated())
        XCTAssertEqual(timeline.presentation(at: 1.74), first.validated())
        XCTAssertEqual(timeline.presentation(at: 1.75), second.validated())
    }

    func testManualZoomEditingPreservesUnrelatedSceneChangesAndRawResetTiming() throws {
        var base = CapturePresentationSnapshot.default
        base.name = "Base"
        var zoom = base
        zoom.framing = ScreenFramingSnapshot(
            mode: .fixedRegion,
            centerX: 0.25,
            centerY: 0.4,
            scale: 0.5
        )
        var layoutDuringZoom = zoom
        layoutDuringZoom.camera.width = 0.42
        var resetLayout = layoutDuringZoom
        resetLayout.framing = base.framing

        var timeline = StudioSceneTimeline(initialPresentation: base)
        timeline.append(zoom, at: 2, kind: .manualZoomStart)
        timeline.append(layoutDuringZoom, at: 4)
        timeline.append(resetLayout, at: 6, kind: .manualZoomReset)

        var marker = try XCTUnwrap(timeline.manualZoomMarkers(sourceDuration: 10).first)
        marker.sourceTime = 3
        marker.centerX = 0.7
        marker.centerY = 0.6
        marker.scale = 0.4
        XCTAssertTrue(timeline.updateManualZoomMarker(marker, sourceDuration: 10))

        XCTAssertEqual(timeline.presentation(at: 2.5), base.validated())
        XCTAssertEqual(timeline.presentation(at: 3).framing.centerX, 0.7, accuracy: 0.001)
        XCTAssertEqual(timeline.presentation(at: 4.5).framing.centerX, 0.7, accuracy: 0.001)
        XCTAssertEqual(timeline.presentation(at: 4.5).camera.width, 0.42, accuracy: 0.001)
        XCTAssertEqual(timeline.presentation(at: 6).framing.mode, .fullDisplay)

        XCTAssertTrue(timeline.removeManualZoomMarker(at: marker.transitionIndex))
        XCTAssertTrue(timeline.manualZoomMarkers(sourceDuration: 10).isEmpty)
        XCTAssertEqual(timeline.presentation(at: 3.5).framing.mode, .fullDisplay)
        XCTAssertEqual(timeline.presentation(at: 4.5).framing.mode, .fullDisplay)
        XCTAssertEqual(timeline.presentation(at: 4.5).camera.width, 0.42, accuracy: 0.001)
    }

    func testManualZoomDetectionDoesNotExposeAFullSceneChange() {
        let base = CapturePresentationSnapshot.default
        var scene = base
        scene.framing = ScreenFramingSnapshot(mode: .fixedRegion, scale: 0.5)
        var timeline = StudioSceneTimeline(initialPresentation: base)
        timeline.append(scene, at: 2)

        XCTAssertTrue(timeline.manualZoomMarkers(sourceDuration: 10).isEmpty)
    }

    func testLegacyTransitionWithoutProvenanceDefaultsToScene() throws {
        let base = CapturePresentationSnapshot.default
        var zoom = base
        zoom.framing = ScreenFramingSnapshot(mode: .fixedRegion, scale: 0.5)
        var timeline = StudioSceneTimeline(initialPresentation: base)
        timeline.append(zoom, at: 2, kind: .manualZoomStart)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(timeline)) as? [String: Any]
        )
        var transitions = try XCTUnwrap(object["transitions"] as? [[String: Any]])
        transitions[1].removeValue(forKey: "kind")
        object["transitions"] = transitions
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(StudioSceneTimeline.self, from: legacyData)

        XCTAssertEqual(decoded.transitions[1].kind, .scene)
        XCTAssertTrue(decoded.manualZoomMarkers(sourceDuration: 10).isEmpty)
    }

    func testLiveSwitchRejectsCanvasCameraAndUnavailableFollowCursorChanges() {
        var initial = CapturePresentationSnapshot.default
        initial.canvas = CaptureCanvasSnapshot(preset: .fullHD)
        initial.camera.isVisible = false
        let contract = StudioSceneLiveContract(
            initialPresentation: initial,
            capturesCamera: false,
            recordsCursorTelemetry: false
        )

        var compatible = initial
        compatible.screen.width = 0.82
        XCTAssertNil(contract.incompatibility(for: compatible))

        var differentCanvas = compatible
        differentCanvas.canvas = CaptureCanvasSnapshot(preset: .verticalHD)
        XCTAssertEqual(contract.incompatibility(for: differentCanvas), .canvasChanged)

        var needsCamera = compatible
        needsCamera.camera.isVisible = true
        XCTAssertEqual(contract.incompatibility(for: needsCamera), .cameraUnavailable)

        var needsCursor = compatible
        needsCursor.framing.mode = .followCursor
        XCTAssertEqual(contract.incompatibility(for: needsCursor), .cursorTelemetryUnavailable)
    }
}
