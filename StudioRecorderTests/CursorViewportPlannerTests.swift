import CoreGraphics
import XCTest
@testable import StudioRecorder

final class CursorViewportPlannerTests: XCTestCase {
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
