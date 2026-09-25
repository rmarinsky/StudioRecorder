import CoreMedia
import XCTest
@testable import StudioRecorder

@MainActor
final class StudioSceneTests: XCTestCase {
    func testEditorSceneOverrideRestoresRecordedSceneAtEndAndFollowsSourceAfterReorder() throws {
        var wide = CapturePresentationSnapshot.default
        wide.name = "Wide"
        var camera = wide
        camera.name = "Camera"
        camera.camera.isVisible = true
        var later = wide
        later.name = "Later"
        var scenes = StudioSceneTimeline(initialPresentation: wide, displayID: 1)
        scenes.append(later, at: 5, displayID: 1)

        try scenes.overrideScene(
            in: 2..<7, sourceDuration: 10,
            with: camera, displayID: 2,
            transition: .cut
        )

        XCTAssertEqual(scenes.presentation(at: 1).name, "Wide")
        XCTAssertEqual(scenes.presentation(at: 3).name, "Camera")
        XCTAssertEqual(scenes.displayID(at: 3), 2)
        XCTAssertEqual(scenes.presentation(at: 8).name, "Later")
        XCTAssertEqual(scenes.displayID(at: 8), 1)

        var edit = try ProjectEditTimeline(trackID: "screen", sourceDuration: 10)
        try edit.split(at: 5)
        try edit.move(segmentID: edit.segments[0].id, toIndex: 1)
        XCTAssertEqual(scenes.presentation(at: try XCTUnwrap(edit.sourceTime(at: 0.5))).name, "Camera")
        XCTAssertEqual(scenes.presentation(at: try XCTUnwrap(edit.sourceTime(at: 8))).name, "Camera")
    }

    func testSceneOverrideRestoresRecordedSwitchJustInsideRoundedEnd() throws {
        var initial = CapturePresentationSnapshot.default
        initial.name = "Initial"
        var recorded = initial
        recorded.name = "Recorded"
        var override = initial
        override.name = "Override"
        var scenes = StudioSceneTimeline(initialPresentation: initial)
        scenes.append(recorded, at: 5)

        try scenes.overrideScene(in: 2..<5.0000001, sourceDuration: 10,
                                 with: override, displayID: nil, transition: .cut)

        XCTAssertEqual(scenes.presentation(at: 4).name, "Override")
        XCTAssertEqual(scenes.presentation(at: 6).name, "Recorded")
    }

    func testAutomaticCameraOrientationPreservesTheSessionNativeRotation() {
        XCTAssertNil(CameraOrientationApplier.rotationAngle(for: .automatic))
        XCTAssertEqual(CameraOrientationApplier.rotationAngle(for: .landscape), 0)
        XCTAssertEqual(CameraOrientationApplier.rotationAngle(for: .portrait), 90)
    }

    func testSceneSourcesUseProfileDisplaySelectionWithoutLookingModified() {
        var draft = PreferencesStore().makeStudioDraft(
            displays: [AvailableDisplay(id: 7, title: "Display", pixelSize: CGSize(width: 1_920, height: 1_080))],
            microphones: []
        )
        draft.defaultDisplayIDs = [7]
        draft.selectedDisplayIDs = [7]

        XCTAssertNil(StudioSceneSourceState(draft: draft).selectedDisplayIDs)

        draft.selectedDisplayIDs = []
        XCTAssertEqual(StudioSceneSourceState(draft: draft).selectedDisplayIDs, [])
    }

    func testRecordingBoundaryFadeUsesAQuarterSecondAtBothEnds() {
        XCTAssertEqual(StudioRecordingBoundaryFade.opacity(at: 0, outputDuration: 2), 0)
        XCTAssertEqual(StudioRecordingBoundaryFade.opacity(at: 0.125, outputDuration: 2), 0.5)
        XCTAssertEqual(StudioRecordingBoundaryFade.opacity(at: 0.25, outputDuration: 2), 1)
        XCTAssertEqual(StudioRecordingBoundaryFade.opacity(at: 1, outputDuration: 2), 1)
        XCTAssertEqual(StudioRecordingBoundaryFade.opacity(at: 1.875, outputDuration: 2), 0.5)
        XCTAssertEqual(StudioRecordingBoundaryFade.opacity(at: 2, outputDuration: 2), 0)
    }

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

    func testSmoothMoveUsesTheSameInterpolationInLiveResolverAndSavedTimeline() {
        var start = CapturePresentationSnapshot.default
        start.camera.shape = .rectangle
        start.camera.width = 0.2
        var target = start
        target.camera.width = 0.6
        let startHostTime = CMClockConvertHostTimeToSystemUnits(
            CMTime(seconds: 10, preferredTimescale: 1_000_000)
        )
        let midHostTime = CMClockConvertHostTimeToSystemUnits(
            CMTime(seconds: 10.15, preferredTimescale: 1_000_000)
        )
        let configuration = StudioSceneTransitionConfiguration(effect: .smoothMove, duration: 0.3)
        var resolver = StudioSceneSwitchResolver(initialPresentation: start)
        resolver.schedule(StudioSceneSwitchEvent(
            sequence: 1,
            hostTime: startHostTime,
            presentation: target,
            kind: .scene,
            transition: configuration
        ))
        var timeline = StudioSceneTimeline(initialPresentation: start)
        timeline.append(target, at: 2, transition: configuration)

        let live = resolver.resolve(forFrameHostTime: midHostTime)
        let saved = timeline.presentation(at: 2.15)

        XCTAssertEqual(live.camera.width, 0.4, accuracy: 0.01)
        XCTAssertEqual(saved.camera.width, live.camera.width, accuracy: 0.01)
        XCTAssertEqual(timeline.presentation(at: 2.3), target.validated())
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
        updated.presentation.camera.shadow = SourceShadowSnapshot()
        updated.presentation.imageOverlays = [ImageOverlaySnapshot(
            name: "Logo",
            filePath: "/tmp/logo.png",
            placement: SourcePlacementSnapshot(
                centerX: 0.8,
                centerY: 0.2,
                width: 0.2,
                shape: .rectangle
            )
        )]
        try store.save(updated)

        let reloaded = StudioSceneLibraryStore(fileURL: url)
        var expected = updated
        expected.configuration = .desktop
        XCTAssertEqual(reloaded.scenes, [expected])
        XCTAssertEqual(reloaded.scenes.first?.name, "Interview")
    }

    func testLibraryPersistsProfilesAndCompleteSceneSourceState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "StudioSceneTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "scenes.json")
        let store = StudioSceneLibraryStore(fileURL: url)
        var configuration = StudioProfileConfiguration.desktop
        configuration.frameRate = 60
        configuration.cameraOrientation = .portrait
        configuration.socialGuide = .tikTok
        try store.updateActiveConfiguration(configuration)
        var presentation = CapturePresentationSnapshot.default
        presentation.name = "Full Camera"
        presentation.screen.isVisible = false
        let scene = StudioScenePreset(
            presentation: presentation,
            sources: StudioSceneSourceState(
                selectedDisplayIDs: [],
                capturesSystemAudio: false,
                capturesMicrophone: true,
                capturesCamera: true
            ),
            incomingTransition: StudioSceneTransitionConfiguration(effect: .dissolve, duration: 0.45)
        )
        try store.save(scene)
        try store.selectScene(scene.id)

        let reloaded = StudioSceneLibraryStore(fileURL: url)

        XCTAssertEqual(reloaded.activeProfile?.configuration, configuration)
        XCTAssertEqual(reloaded.activeProfile?.lastSceneID, scene.id)
        var expected = scene
        expected.configuration = configuration
        XCTAssertEqual(reloaded.scenes, [expected])
    }

    func testLibraryPersistsSceneOrderingForLiveSwitcherShortcuts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "StudioSceneTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "scenes.json")
        let store = StudioSceneLibraryStore(fileURL: url)

        var widePresentation = CapturePresentationSnapshot.default
        widePresentation.name = "Wide"
        let wide = StudioScenePreset(presentation: widePresentation)
        var cameraPresentation = CapturePresentationSnapshot.default
        cameraPresentation.name = "Camera"
        let camera = StudioScenePreset(presentation: cameraPresentation)
        var demoPresentation = CapturePresentationSnapshot.default
        demoPresentation.name = "Demo"
        let demo = StudioScenePreset(presentation: demoPresentation)
        try store.save(wide)
        try store.save(camera)
        try store.save(demo)

        try store.move(demo.id, by: -2)
        try store.move(wide.id, by: 20)

        XCTAssertEqual(store.scenes.map(\.name), ["Demo", "Camera", "Wide"])
        XCTAssertEqual(
            StudioSceneLibraryStore(fileURL: url).scenes.map(\.id),
            [demo.id, camera.id, wide.id]
        )
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

    func testTimelinePreservesDisplayOnlySwitchesForFollowCursorRecording() {
        let presentation = CapturePresentationSnapshot.default
        var timeline = StudioSceneTimeline(initialPresentation: presentation, displayID: 1)

        timeline.append(presentation, at: 2.5, displayID: 2)

        XCTAssertEqual(timeline.transitions.count, 2)
        XCTAssertEqual(timeline.displayID(at: 2.49), 1)
        XCTAssertEqual(timeline.displayID(at: 2.5), 2)
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
