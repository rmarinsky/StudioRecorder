import CoreGraphics
import XCTest
@testable import StudioRecorder

final class CursorViewportPlannerTests: XCTestCase {
    func testDelayedFrameUsesCursorPositionFromItsDisplayTimeInsteadOfTheNewerDeliveryPosition() throws {
        let synchronizer = CursorFrameSynchronizer(historyLimit: 8)
        synchronizer.record(
            CursorHostSample(
                hostTime: 100,
                location: CGPoint(x: 200, y: 400),
                isPrimaryButtonDown: true
            )
        )
        synchronizer.record(
            CursorHostSample(
                hostTime: 200,
                location: CGPoint(x: 800, y: 400),
                isPrimaryButtonDown: true
            )
        )

        let frameAligned = try XCTUnwrap(synchronizer.sample(forFrameAt: 150))

        XCTAssertEqual(frameAligned.location.x, 200)
        XCTAssertTrue(frameAligned.isPrimaryButtonDown)
    }

    func testFrameAlignmentNormalizesCursorInsideTheActuallyCapturedRegion() throws {
        let synchronizer = CursorFrameSynchronizer(historyLimit: 8)
        let streamID = ObjectIdentifier(NSObject())
        synchronizer.register(
            streamID: streamID,
            space: CursorCaptureSpace(
                displayID: 7,
                visibleFrame: CGRect(x: 1_000, y: 200, width: 800, height: 600)
            )
        )
        synchronizer.record(
            CursorHostSample(
                hostTime: 100,
                location: CGPoint(x: 1_200, y: 500),
                isPrimaryButtonDown: false
            )
        )

        let aligned = try XCTUnwrap(synchronizer.alignFrame(streamID: streamID, hostTime: 100))

        XCTAssertEqual(aligned.normalizedX, 0.25, accuracy: 0.001)
        XCTAssertEqual(aligned.normalizedY, 0.5, accuracy: 0.001)
        XCTAssertEqual(aligned.time, 0, accuracy: 0.001)
    }

    func testRecordedCursorTimelineReturnsTheScenePositionAtPlaybackTime() throws {
        let timeline = CursorSceneTimeline(samples: [
            CursorSceneSample(time: 0, displayID: 7, normalizedX: 0.15, normalizedY: 0.4, isPrimaryButtonDown: false),
            CursorSceneSample(time: 1, displayID: 7, normalizedX: 0.85, normalizedY: 0.6, isPrimaryButtonDown: true),
            CursorSceneSample(time: 1.2, displayID: 8, normalizedX: 0.3, normalizedY: 0.2, isPrimaryButtonDown: false),
        ])

        XCTAssertEqual(try XCTUnwrap(timeline.sample(at: 0.5, for: 7)).normalizedX, 0.15)
        XCTAssertEqual(try XCTUnwrap(timeline.sample(at: 1.1, for: 7)).normalizedX, 0.85)
        XCTAssertTrue(try XCTUnwrap(timeline.sample(at: 1.1, for: 7)).isPrimaryButtonDown)
        XCTAssertEqual(try XCTUnwrap(timeline.sample(at: 1.3, for: 8)).normalizedY, 0.2)
    }

    func testCrossingDisplaysWaitsForDwellBeforeSwitchingProgramSource() {
        let displays = [
            CapturedDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
            CapturedDisplay(id: 2, frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
        ]
        var planner = CursorViewportPlanner(displays: displays)

        XCTAssertEqual(planner.update(cursor: CGPoint(x: 960, y: 540), at: 0).displayID, 1)
        XCTAssertEqual(planner.update(cursor: CGPoint(x: 2500, y: 540), at: 0.1).displayID, 1)

        let switched = planner.update(cursor: CGPoint(x: 2500, y: 540), at: 0.26)
        XCTAssertEqual(switched.displayID, 2)
        XCTAssertEqual(switched.transition, .crossfade)
    }

    func testViewportRecentersOnlyAfterCursorLeavesSafeZone() {
        let display = CapturedDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 3840, height: 1200))
        var planner = CursorViewportPlanner(displays: [display], outputSize: CGSize(width: 1920, height: 1080))

        let centered = planner.update(cursor: CGPoint(x: 1920, y: 600), at: 0)
        let moved = planner.update(cursor: CGPoint(x: 3500, y: 600), at: 0.2)

        XCTAssertEqual(centered.viewport.midX, 1920, accuracy: 0.1)
        XCTAssertGreaterThan(moved.viewport.midX, centered.viewport.midX)
        XCTAssertLessThanOrEqual(moved.viewport.maxX, display.frame.maxX)
    }
}
