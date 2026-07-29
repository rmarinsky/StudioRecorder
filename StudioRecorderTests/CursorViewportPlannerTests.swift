import CoreGraphics
import XCTest
@testable import StudioRecorder

final class CursorViewportPlannerTests: XCTestCase {
    func testFrameAlignmentUsesScreenContentLatencyInsteadOfLeadingTextSelection() throws {
        let synchronizer = CursorFrameSynchronizer(
            historyLimit: 8,
            contentLatencySystemUnits: 20
        )
        synchronizer.record(
            CursorHostSample(
                hostTime: 180,
                location: CGPoint(x: 420, y: 400),
                isPrimaryButtonDown: true
            )
        )
        synchronizer.record(
            CursorHostSample(
                hostTime: 200,
                location: CGPoint(x: 460, y: 400),
                isPrimaryButtonDown: true
            )
        )

        let frameAligned = try XCTUnwrap(synchronizer.sample(forFrameAt: 200))

        XCTAssertEqual(frameAligned.location.x, 420)
    }

    func testContentLatencyFallsBackToCurrentSampleWhileHistoryWarmsUp() throws {
        let synchronizer = CursorFrameSynchronizer(
            historyLimit: 8,
            contentLatencySystemUnits: 20
        )
        synchronizer.record(
            CursorHostSample(
                hostTime: 200,
                location: CGPoint(x: 460, y: 400),
                isPrimaryButtonDown: false
            )
        )

        let frameAligned = try XCTUnwrap(synchronizer.sample(forFrameAt: 200))

        XCTAssertEqual(frameAligned.location.x, 460)
    }

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

    func testCursorTimelineOnlyRecordsTheDisplayContainingTheCursor() throws {
        let synchronizer = CursorFrameSynchronizer(historyLimit: 8)
        let firstStream = NSObject()
        let secondStream = NSObject()
        let firstStreamID = ObjectIdentifier(firstStream)
        let secondStreamID = ObjectIdentifier(secondStream)
        synchronizer.register(
            streamID: firstStreamID,
            space: CursorCaptureSpace(
                displayID: 1,
                visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
            )
        )
        synchronizer.register(
            streamID: secondStreamID,
            space: CursorCaptureSpace(
                displayID: 2,
                visibleFrame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800)
            )
        )
        synchronizer.record(
            CursorHostSample(
                hostTime: 100,
                location: CGPoint(x: 500, y: 400),
                isPrimaryButtonDown: false
            )
        )

        _ = synchronizer.alignFrame(streamID: firstStreamID, hostTime: 100)
        _ = synchronizer.alignFrame(streamID: secondStreamID, hostTime: 100)

        let samples = synchronizer.timelineSamples()
        XCTAssertEqual(samples.count, 1)
        let sample = try XCTUnwrap(samples.first)
        XCTAssertEqual(sample.displayID, 1)
        XCTAssertEqual(sample.normalizedX, 0.5, accuracy: 0.001)
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

    func testFollowMotionApproachesTargetWithoutOvershootingOrTrailing() {
        var motion = CursorFollowMotion(responseDuration: 0.4)
        _ = motion.update(target: CGPoint(x: 0, y: 0), at: 0)

        var previous = CGPoint.zero
        for frame in 1...60 {
            let next = motion.update(
                target: CGPoint(x: 1, y: 1),
                at: Double(frame) / 60
            )
            XCTAssertGreaterThanOrEqual(next.x, previous.x)
            XCTAssertGreaterThanOrEqual(next.y, previous.y)
            XCTAssertLessThanOrEqual(next.x, 1)
            XCTAssertLessThanOrEqual(next.y, 1)
            previous = next
        }

        XCTAssertEqual(previous.x, 1, accuracy: 0.001)
        XCTAssertEqual(previous.y, 1, accuracy: 0.001)
    }

    func testFollowMotionHasEquivalentTrajectoriesAtThirtyAndSixtyFPS() {
        func center(after duration: TimeInterval, frameRate: Int) -> CGPoint {
            var motion = CursorFollowMotion(responseDuration: 0.4)
            _ = motion.update(target: .zero, at: 0)
            for frame in 1...Int(duration * Double(frameRate)) {
                _ = motion.update(
                    target: CGPoint(x: 1, y: 0.75),
                    at: Double(frame) / Double(frameRate)
                )
            }
            return motion.center ?? .zero
        }

        let thirtyFPS = center(after: 0.5, frameRate: 30)
        let sixtyFPS = center(after: 0.5, frameRate: 60)

        XCTAssertEqual(thirtyFPS.x, sixtyFPS.x, accuracy: 0.0001)
        XCTAssertEqual(thirtyFPS.y, sixtyFPS.y, accuracy: 0.0001)
    }

    func testFollowMotionUsesTheWholeIrregularFrameInterval() {
        var oneLongFrame = CursorFollowMotion(responseDuration: 0.4)
        _ = oneLongFrame.update(target: .zero, at: 0)
        let longFrameCenter = oneLongFrame.update(target: CGPoint(x: 1, y: 1), at: 0.2)

        var regularFrames = CursorFollowMotion(responseDuration: 0.4)
        _ = regularFrames.update(target: .zero, at: 0)
        for frame in 1...6 {
            _ = regularFrames.update(
                target: CGPoint(x: 1, y: 1),
                at: Double(frame) / 30
            )
        }

        XCTAssertEqual(longFrameCenter.x, regularFrames.center?.x ?? 0, accuracy: 0.0001)
        XCTAssertEqual(longFrameCenter.y, regularFrames.center?.y ?? 0, accuracy: 0.0001)
    }

    func testFollowMotionResetsOnFirstAndNonMonotonicSamples() {
        var motion = CursorFollowMotion(initialCenter: CGPoint(x: 0.5, y: 0.5))

        let first = motion.update(target: CGPoint(x: 0.2, y: 0.3), at: 1)
        XCTAssertEqual(first.x, 0.2, accuracy: 0.0001)
        XCTAssertEqual(first.y, 0.3, accuracy: 0.0001)

        _ = motion.update(target: CGPoint(x: 0.8, y: 0.9), at: 1.1)
        XCTAssertFalse(motion.isSettled)

        let repeated = motion.update(target: CGPoint(x: 0.4, y: 0.6), at: 1.1)
        XCTAssertEqual(repeated.x, 0.4, accuracy: 0.0001)
        XCTAssertEqual(repeated.y, 0.6, accuracy: 0.0001)
        XCTAssertTrue(motion.isSettled)

        let backwards = motion.update(target: CGPoint(x: 0.7, y: 0.1), at: 1)
        XCTAssertEqual(backwards.x, 0.7, accuracy: 0.0001)
        XCTAssertEqual(backwards.y, 0.1, accuracy: 0.0001)
        XCTAssertTrue(motion.isSettled)
    }

    func testFollowMotionResetsAfterAFrameGapOverQuarterSecond() {
        var motion = CursorFollowMotion()
        _ = motion.update(target: .zero, at: 0)
        _ = motion.update(target: CGPoint(x: 1, y: 1), at: 0.1)

        let reset = motion.update(target: CGPoint(x: 0.25, y: 0.75), at: 0.351)

        XCTAssertEqual(reset.x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(reset.y, 0.75, accuracy: 0.0001)
        XCTAssertTrue(motion.isSettled)
    }

    func testDefaultFollowMotionIsSmootherThanTheLegacyResponse() {
        var smoother = CursorFollowMotion()
        var legacy = CursorFollowMotion(responseDuration: 0.4)
        _ = smoother.update(target: .zero, at: 0)
        _ = legacy.update(target: .zero, at: 0)

        for frame in 1...12 {
            let timestamp = Double(frame) / 60
            _ = smoother.update(target: CGPoint(x: 1, y: 1), at: timestamp)
            _ = legacy.update(target: CGPoint(x: 1, y: 1), at: timestamp)
        }

        XCTAssertLessThan(smoother.center?.x ?? 0, legacy.center?.x ?? 0)
        XCTAssertGreaterThan(smoother.center?.x ?? 0, 0)
    }

    func testFollowMotionResetClearsVelocityAndTiming() {
        var motion = CursorFollowMotion()
        _ = motion.update(target: .zero, at: 0)
        _ = motion.update(target: CGPoint(x: 1, y: 1), at: 0.1)

        motion.reset(to: CGPoint(x: 0.5, y: 0.5))

        XCTAssertEqual(motion.center?.x ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(motion.center?.y ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertTrue(motion.isSettled)
        let firstAfterReset = motion.update(target: CGPoint(x: 0.1, y: 0.9), at: 10)
        XCTAssertEqual(firstAfterReset.x, 0.1, accuracy: 0.0001)
        XCTAssertEqual(firstAfterReset.y, 0.9, accuracy: 0.0001)
    }
}
