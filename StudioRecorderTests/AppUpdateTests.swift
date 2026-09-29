import XCTest
import Sparkle
@testable import StudioRecorder

final class AppUpdateTests: XCTestCase {
    @MainActor
    func testDepartingBusyOwnerRemainsProtectedUntilItsWorkFinishes() async {
        var snapshot = StudioRecorderSnapshot()
        snapshot.captureState = .ready
        let updates = AppUpdateController(
            model: StudioRecorderModel(coordinator: nil, initialSnapshot: snapshot), bundle: Bundle(for: Self.self)
        )
        let sparkle = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        ).updater
        let owner = UUID()
        var busy = true
        updates.registerActivity(owner) { busy }
        updates.updater(sparkle, willInstallUpdate: .empty())
        updates.unregisterActivity(owner)
        let resumed = expectation(description: "Departing owner's work finishes")
        XCTAssertTrue(updates.postponeTerminationIfNeeded { allowed in
            XCTAssertTrue(allowed)
            resumed.fulfill()
        })
        busy = false
        await fulfillment(of: [resumed], timeout: 3)
        XCTAssertFalse(updates.isWaitingForIdle)
    }

    @MainActor
    func testUpdateTerminationWaitsEvenIfSparkleSkipsItsPostponementCallback() async {
        var snapshot = StudioRecorderSnapshot()
        snapshot.captureState = .ready
        let model = StudioRecorderModel(coordinator: nil, initialSnapshot: snapshot)
        let updates = AppUpdateController(model: model, bundle: Bundle(for: Self.self))
        let sparkle = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        ).updater
        var busy = true
        updates.registerActivity(UUID()) { busy }
        XCTAssertFalse(updates.postponeTerminationIfNeeded { _ in XCTFail("Regular quit is unchanged") })

        updates.updater(sparkle, willInstallUpdate: .empty())
        let resumed = expectation(description: "Installation resumes after media work finishes")
        XCTAssertTrue(updates.postponeTerminationIfNeeded {
            XCTAssertTrue($0)
            resumed.fulfill()
        })
        XCTAssertTrue(updates.isWaitingForIdle)
        busy = false
        await fulfillment(of: [resumed], timeout: 3)
        XCTAssertFalse(updates.isWaitingForIdle)
    }

    @MainActor
    func testCaptureAndPendingJobsPreventUpdateTermination() {
        let sparkle = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        ).updater
        var snapshots: [StudioRecorderSnapshot] = []
        for state: RecordingState in [.recording, .paused, .stopping] {
            var snapshot = StudioRecorderSnapshot()
            snapshot.captureState = state
            snapshots.append(snapshot)
        }
        for state: RecordingJobState in [.queued, .running] {
            var snapshot = StudioRecorderSnapshot()
            snapshot.captureState = .ready
            var job = RecordingJob(projectID: UUID(), kind: .export)
            job.state = state
            snapshot.jobs = [job]
            snapshots.append(snapshot)
        }
        for snapshot in snapshots {
            let model = StudioRecorderModel(coordinator: nil, initialSnapshot: snapshot)
            let updates = AppUpdateController(model: model, bundle: Bundle(for: Self.self))
            updates.updater(sparkle, willInstallUpdate: .empty())
            var cancelled = false
            XCTAssertTrue(updates.postponeTerminationIfNeeded { cancelled = !$0 })
            updates.updater(sparkle, didAbortWithError: NSError(domain: "test", code: 1))
            XCTAssertTrue(cancelled, "An aborted install must release a pending termination request")
        }
    }

    @MainActor
    func testInstallationWaitsForMediaWorkAndRunsOnlyOnceWhenIdle() {
        let gate = UpdateInstallationGate()
        var installed = false
        XCTAssertTrue(gate.postponeIfBusy(true) { installed = true })
        gate.resumeIfIdle(true)
        XCTAssertFalse(installed)
        gate.resumeIfIdle(false)
        XCTAssertTrue(installed)
        installed = false
        gate.resumeIfIdle(false)
        XCTAssertFalse(installed)
        XCTAssertFalse(gate.postponeIfBusy(false) { installed = true })
        XCTAssertFalse(installed)
    }

    func testOnlyConfiguredProductionBuildsEnableUpdates() {
        let info: [String: Any] = [
            "StudioRecorderUpdatesEnabled": "YES",
            "SUFeedURL": "https://github.com/rmarinsky/StudioRecorder/releases/latest/download/appcast.xml",
            "SUPublicEDKey": "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=",
        ]
        XCTAssertTrue(AppUpdateConfiguration(info: info, bundleIdentifier: "ua.com.rmarinsky.studiorecorder").isEnabled)
        XCTAssertFalse(AppUpdateConfiguration(info: info, bundleIdentifier: "ua.com.rmarinsky.studiorecorder.dev").isEnabled)
        for (key, value) in [
            ("StudioRecorderUpdatesEnabled", "NO"),
            ("SUFeedURL", "http://example.com/appcast.xml"),
            ("SUPublicEDKey", ""),
            ("SUPublicEDKey", "$(SPARKLE_PUBLIC_KEY)"),
        ] {
            var invalid = info
            invalid[key] = value
            XCTAssertFalse(AppUpdateConfiguration(info: invalid, bundleIdentifier: "ua.com.rmarinsky.studiorecorder").isEnabled, key)
        }
    }
}
