import XCTest
@testable import StudioRecorder

final class AppUpdateTests: XCTestCase {
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
