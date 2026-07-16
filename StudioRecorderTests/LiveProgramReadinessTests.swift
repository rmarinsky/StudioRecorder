import XCTest
@testable import StudioRecorder

final class LiveProgramReadinessTests: XCTestCase {
    private let displayID: UInt32 = 7

    private var expectedPresentation: CapturePresentationSnapshot {
        var presentation = CapturePresentationSnapshot.default
        presentation.name = "Prepared stage"
        presentation.camera.isVisible = true
        return presentation.validated()
    }

    func testStaleAndWrongStreamScreenFramesCannotSatisfyAnAttempt() {
        let tracker = LiveProgramReadinessTracker()
        let attempt = tracker.begin(
            displayID: displayID,
            presentation: expectedPresentation,
            requiresCamera: false,
            screenStreamGeneration: 4,
            cameraOutputGeneration: 9,
            at: 10
        )

        tracker.recordScreen(
            displayID: displayID,
            streamGeneration: 4,
            presentation: expectedPresentation,
            at: 9.99
        )
        tracker.recordScreen(
            displayID: displayID,
            streamGeneration: 3,
            presentation: expectedPresentation,
            at: 11
        )
        tracker.recordScreen(
            displayID: 99,
            streamGeneration: 4,
            presentation: expectedPresentation,
            at: 11
        )

        XCTAssertEqual(tracker.blockers(for: attempt.id), [.screen])
    }

    func testFreshScreenMustResolveToTheExactPreparedPresentation() {
        let tracker = LiveProgramReadinessTracker()
        let attempt = tracker.begin(
            displayID: displayID,
            presentation: expectedPresentation,
            requiresCamera: false,
            screenStreamGeneration: 4,
            cameraOutputGeneration: 9,
            at: 10
        )
        var wrongPresentation = expectedPresentation
        wrongPresentation.name = "Old stage"

        tracker.recordScreen(
            displayID: displayID,
            streamGeneration: 4,
            presentation: wrongPresentation,
            at: 11
        )
        XCTAssertEqual(tracker.blockers(for: attempt.id), [.presentation])

        tracker.recordScreen(
            displayID: displayID,
            streamGeneration: 4,
            presentation: expectedPresentation,
            at: 12
        )
        XCTAssertEqual(tracker.blockers(for: attempt.id), [])
    }

    func testVisibleCameraRequiresFreshCurrentOutputEvidenceInEitherOrder() {
        let tracker = LiveProgramReadinessTracker()
        let attempt = tracker.begin(
            displayID: displayID,
            presentation: expectedPresentation,
            requiresCamera: true,
            screenStreamGeneration: 4,
            cameraOutputGeneration: 9,
            at: 10
        )

        tracker.recordCamera(outputGeneration: 8, at: 11)
        tracker.recordCamera(outputGeneration: 9, at: 9.5)
        tracker.recordCamera(outputGeneration: 9, at: 11)
        XCTAssertEqual(tracker.blockers(for: attempt.id), [.screen])

        tracker.recordScreen(
            displayID: displayID,
            streamGeneration: 4,
            presentation: expectedPresentation,
            at: 12
        )
        XCTAssertEqual(tracker.blockers(for: attempt.id), [])
    }

    func testHiddenOrDisabledCameraDoesNotBlockThePreparedStage() {
        let tracker = LiveProgramReadinessTracker()
        let attempt = tracker.begin(
            displayID: displayID,
            presentation: expectedPresentation,
            requiresCamera: false,
            screenStreamGeneration: 4,
            cameraOutputGeneration: nil,
            at: 10
        )

        tracker.recordScreen(
            displayID: displayID,
            streamGeneration: 4,
            presentation: expectedPresentation,
            at: 11
        )
        XCTAssertEqual(tracker.blockers(for: attempt.id), [])
    }

    func testNewAttemptInvalidatesOldEvidenceAndOldWaiter() {
        let tracker = LiveProgramReadinessTracker()
        let first = tracker.begin(
            displayID: displayID,
            presentation: expectedPresentation,
            requiresCamera: false,
            screenStreamGeneration: 4,
            cameraOutputGeneration: nil,
            at: 10
        )
        tracker.recordScreen(
            displayID: displayID,
            streamGeneration: 4,
            presentation: expectedPresentation,
            at: 11
        )
        XCTAssertEqual(tracker.blockers(for: first.id), [])

        let second = tracker.begin(
            displayID: displayID,
            presentation: expectedPresentation,
            requiresCamera: false,
            screenStreamGeneration: 5,
            cameraOutputGeneration: nil,
            at: 12
        )

        XCTAssertNil(tracker.blockers(for: first.id))
        XCTAssertEqual(tracker.blockers(for: second.id), [.screen])
    }

    func testTimeoutErrorPrioritizesTheMissingMediaSource() {
        XCTAssertEqual(
            LiveProgramReadinessError(blockers: [.screen, .presentation]),
            .screenUnavailable
        )
        XCTAssertEqual(
            LiveProgramReadinessError(blockers: [.camera, .presentation]),
            .cameraUnavailable
        )
        XCTAssertEqual(
            LiveProgramReadinessError(blockers: [.presentation]),
            .presentationUnavailable
        )
    }
}
