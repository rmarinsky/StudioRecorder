import XCTest
@testable import StudioRecorder

@MainActor
final class StudioSceneTests: XCTestCase {
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
