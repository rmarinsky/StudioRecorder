import XCTest
@testable import StudioRecorder

final class SegmentRecoveryPlannerTests: XCTestCase {
    func testRecoveryKeepsFinalizedSegmentsAndReportsOnlyTheIncompleteTail() {
        let plan = SegmentRecoveryPlanner.recover([
            RecordingSegment(id: "screen-001", duration: 60, isFinalized: true),
            RecordingSegment(id: "screen-002", duration: 60, isFinalized: true),
            RecordingSegment(id: "screen-003", duration: 10, isFinalized: false)
        ])

        XCTAssertEqual(plan.recovered.map(\.id), ["screen-001", "screen-002"])
        XCTAssertEqual(plan.discarded.map(\.id), ["screen-003"])
        XCTAssertEqual(plan.recoveredDuration, 120, accuracy: 0.001)
    }
}
