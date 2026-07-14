import XCTest
@testable import StudioRecorder

@MainActor
final class StudioRecorderModelTests: XCTestCase {
    func testNewRecordingRoutesToStudioAndClearsProjectSelection() {
        var snapshot = StudioRecorderSnapshot()
        snapshot.selectedProjectID = UUID().uuidString
        let model = StudioRecorderModel(coordinator: nil, initialSnapshot: snapshot)

        XCTAssertEqual(model.send(.newRecording), .routeChanged(.studio))
        XCTAssertEqual(model.snapshot.route, .studio)
        XCTAssertNil(model.snapshot.selectedProjectID)
    }

    func testRecoveryRouteRequiresAnInterruptedProject() {
        let emptyModel = StudioRecorderModel(coordinator: nil, initialSnapshot: StudioRecorderSnapshot())
        XCTAssertEqual(emptyModel.send(.selectRoute(.recovery)), .ignored)
        XCTAssertEqual(emptyModel.snapshot.route, .projects)

        var snapshot = StudioRecorderSnapshot()
        snapshot.interruptedProjects = [interruptedProject()]
        let recoveryModel = StudioRecorderModel(coordinator: nil, initialSnapshot: snapshot)

        XCTAssertEqual(recoveryModel.send(.selectRoute(.recovery)), .routeChanged(.recovery))
        XCTAssertEqual(recoveryModel.snapshot.route, .recovery)
    }

    func testRecordCommandStartsOnceUntilRuntimeStateChanges() {
        var snapshot = StudioRecorderSnapshot()
        snapshot.route = .studio
        snapshot.captureState = .ready
        snapshot.availableDisplays = [AvailableDisplay(id: 7, title: "Test Display", pixelSize: .zero)]
        snapshot.selectedDisplayIDs = [7]
        let model = StudioRecorderModel(coordinator: nil, initialSnapshot: snapshot)

        XCTAssertEqual(model.send(.toggleRecording), .recordingStartRequested([7]))
        XCTAssertTrue(model.snapshot.isCaptureCommandInFlight)
        XCTAssertEqual(model.send(.toggleRecording), .ignored)

        var synchronized = model.snapshot
        synchronized.applyCaptureState(.ready)
        XCTAssertTrue(synchronized.isCaptureCommandInFlight)
        synchronized.applyCaptureState(.preparing)
        XCTAssertFalse(synchronized.isCaptureCommandInFlight)
    }

    func testFindProjectsReturnsToProjectsAndRequestsSearchFocus() {
        var snapshot = StudioRecorderSnapshot()
        snapshot.route = .studio
        let model = StudioRecorderModel(coordinator: nil, initialSnapshot: snapshot)

        XCTAssertEqual(model.send(.focusProjectSearch), .projectSearchRequested)
        XCTAssertEqual(model.snapshot.route, .projects)
    }

    func testRecordCommandStopsAnActiveSessionOutsideStudio() {
        var snapshot = StudioRecorderSnapshot()
        snapshot.route = .projects
        snapshot.captureState = .recording
        let model = StudioRecorderModel(coordinator: nil, initialSnapshot: snapshot)

        XCTAssertEqual(model.send(.toggleRecording), .recordingStopRequested)
        XCTAssertTrue(model.snapshot.isCaptureCommandInFlight)
    }

    private func interruptedProject() -> RecordingProjectSnapshot {
        RecordingProjectSnapshot(
            identity: RecordingProjectIdentity(
                packageURL: FileManager.default.temporaryDirectory.appending(path: "interrupted.recordingproject"),
                manifestID: UUID()
            ),
            createdAt: .now,
            stoppedAt: nil,
            lifecycle: .needsRecovery,
            captureProfile: "1080p-adaptive-30fps",
            sources: [],
            tracks: [],
            recoveryReport: RecordingProjectRecoveryReport(tracks: [], diagnostics: ["Interrupted"])
        )
    }
}
