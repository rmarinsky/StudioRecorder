import XCTest
@testable import StudioRecorder

final class LiveSourceHealthTests: XCTestCase {
    private let display = LiveSourceID.screen(displayID: 7)

    func testExpectedSourcesWarmUpBeforeReportingAStall() {
        let monitor = LiveSourceHealthMonitor(startupGrace: 3)
        monitor.configure(expected: [display, .camera], at: 10)

        let warming = monitor.snapshot(at: 12.9)
        XCTAssertEqual(warming[display]?.state, .waiting)
        XCTAssertEqual(warming[.camera]?.state, .waiting)
        XCTAssertFalse(warming.hasStalledSources)

        let stalled = monitor.snapshot(at: 13.1)
        XCTAssertEqual(stalled[display]?.state, .stalled)
        XCTAssertEqual(stalled[.camera]?.state, .stalled)
        XCTAssertTrue(stalled.hasStalledSources)
    }

    func testEveryDeliveredSourceBecomesActiveAndCanRecoverAfterAStall() {
        let monitor = LiveSourceHealthMonitor(startupGrace: 1)
        let sources: Set<LiveSourceID> = [display, .camera, .systemAudio, .microphone]
        monitor.configure(expected: sources, at: 0)
        for source in sources {
            monitor.record(source, at: 0.5)
        }

        XCTAssertTrue(monitor.snapshot(at: 1).entries.allSatisfy { $0.state == .active })
        XCTAssertTrue(monitor.snapshot(at: 3).hasStalledSources)

        monitor.record(display, at: 3)
        let recovered = monitor.snapshot(at: 3.1)
        XCTAssertEqual(recovered[display]?.state, .recovered)
        XCTAssertEqual(recovered[.camera]?.state, .stalled)
        monitor.record(display, at: 6)
        XCTAssertEqual(monitor.snapshot(at: 6.1)[display]?.state, .active)
    }

    func testVideoAndAudioUseDifferentSilenceThresholds() {
        let monitor = LiveSourceHealthMonitor(
            startupGrace: 0,
            videoStallThreshold: 1,
            audioStallThreshold: 2
        )
        monitor.configure(expected: [display, .microphone], at: 0)
        monitor.record(display, at: 1)
        monitor.record(.microphone, at: 1)

        let snapshot = monitor.snapshot(at: 2.5)
        XCTAssertEqual(snapshot[display]?.state, .stalled)
        XCTAssertEqual(snapshot[.microphone]?.state, .active)
    }

    func testReconfiguringSourcesRemovesOldStateAndWarmsNewSources() {
        let monitor = LiveSourceHealthMonitor(startupGrace: 2)
        monitor.configure(expected: [display, .camera], at: 0)
        monitor.record(.camera, at: 1)

        monitor.configure(expected: [display, .microphone], at: 5)
        let snapshot = monitor.snapshot(at: 5.5)

        XCTAssertNil(snapshot[.camera])
        XCTAssertEqual(snapshot[display]?.state, .waiting)
        XCTAssertEqual(snapshot[.microphone]?.state, .waiting)
    }

    func testMultipleDisplaysAreTrackedIndependently() {
        let secondDisplay = LiveSourceID.screen(displayID: 9)
        let monitor = LiveSourceHealthMonitor(startupGrace: 0, videoStallThreshold: 1)
        monitor.configure(expected: [display, secondDisplay], at: 0)
        monitor.record(display, at: 2)
        monitor.record(secondDisplay, at: 0.5)

        let snapshot = monitor.snapshot(at: 2.1)

        XCTAssertEqual(snapshot[display]?.state, .active)
        XCTAssertEqual(snapshot[secondDisplay]?.state, .stalled)
        XCTAssertEqual(snapshot.stalledSources, [secondDisplay])
    }
}
