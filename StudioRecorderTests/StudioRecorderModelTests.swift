import AVFoundation
import XCTest
@testable import StudioRecorder

@MainActor
final class StudioRecorderModelTests: XCTestCase {
    func testPermissionRepairPresentationCoversEveryRenderedStateAndAction() throws {
        var snapshot = StudioRecorderSnapshot()
        snapshot.route = .studio
        snapshot.captureState = .ready

        var presentation = try XCTUnwrap(snapshot.permissionRepairPresentation)
        XCTAssertTrue(presentation.showsLoadingSkeleton)
        XCTAssertEqual(presentation.actions, [.browseProjects])

        snapshot.permissionSnapshot = PermissionSnapshot(screenRecording: .denied, microphone: .granted)
        presentation = try XCTUnwrap(snapshot.permissionRepairPresentation)
        XCTAssertEqual(presentation.permission, .screenRecording)
        XCTAssertEqual(presentation.title, "Allow Screen Recording")
        XCTAssertEqual(presentation.screenStatusLabel, "Denied")
        XCTAssertEqual(presentation.actions, [.requestAccess, .openSystemSettings, .checkAgain, .browseProjects])

        snapshot.permissionSnapshot = PermissionSnapshot(screenRecording: .granted, microphone: .notDetermined)
        presentation = try XCTUnwrap(snapshot.permissionRepairPresentation)
        XCTAssertEqual(presentation.permission, .microphone)
        XCTAssertEqual(presentation.title, "Allow Microphone")
        XCTAssertEqual(presentation.actions, [.requestAccess, .recordWithoutMicrophone, .checkAgain, .browseProjects])

        snapshot.permissionSnapshot.microphone = .denied
        presentation = try XCTUnwrap(snapshot.permissionRepairPresentation)
        XCTAssertEqual(presentation.actions, [.openSystemSettings, .recordWithoutMicrophone, .checkAgain, .browseProjects])

        snapshot.permissionSnapshot = PermissionSnapshot(screenRecording: .grantedButRelaunchRequired, microphone: .granted)
        presentation = try XCTUnwrap(snapshot.permissionRepairPresentation)
        XCTAssertEqual(presentation.title, "Relaunch Studio Recorder")
        XCTAssertEqual(presentation.screenStatusLabel, "Granted, relaunch required")

        snapshot.permissionSnapshot = PermissionSnapshot(screenRecording: .unavailable("Framework unavailable."), microphone: .granted)
        presentation = try XCTUnwrap(snapshot.permissionRepairPresentation)
        XCTAssertEqual(presentation.detail, "Framework unavailable.")
        XCTAssertEqual(presentation.actions, [.checkAgain, .browseProjects])

        snapshot.permissionSnapshot = PermissionSnapshot(screenRecording: .granted, microphone: .granted)
        XCTAssertNil(snapshot.permissionRepairPresentation)
    }

    func testPermissionCenterRefreshesLiveSystemState() async {
        var screenIsGranted = false
        var microphoneStatus = AVAuthorizationStatus.notDetermined
        let center = PermissionCenter(
            screenPreflight: { screenIsGranted },
            screenRequest: { false },
            microphoneStatus: { microphoneStatus },
            microphoneRequest: { false },
            openURL: { _ in }
        )

        var snapshot = await center.refresh()
        XCTAssertEqual(snapshot, PermissionSnapshot(screenRecording: .denied, microphone: .notDetermined))

        screenIsGranted = true
        microphoneStatus = .authorized

        snapshot = await center.refresh()
        XCTAssertEqual(snapshot, PermissionSnapshot(screenRecording: .granted, microphone: .granted))
    }

    func testPermissionCenterReportsAcceptedScreenGrantThatNeedsRelaunch() async {
        let center = PermissionCenter(
            screenPreflight: { false },
            screenRequest: { true },
            microphoneStatus: { .authorized },
            microphoneRequest: { true },
            openURL: { _ in }
        )

        await center.request(.screenRecording)

        let snapshot = await center.refresh()
        XCTAssertEqual(snapshot.screenRecording, .grantedButRelaunchRequired)
    }

    func testAppActivationRefreshesGrantedAndRevokedPermissions() async {
        var screenIsGranted = false
        var microphoneStatus = AVAuthorizationStatus.authorized
        let center = PermissionCenter(
            screenPreflight: { screenIsGranted },
            screenRequest: { false },
            microphoneStatus: { microphoneStatus },
            microphoneRequest: { true },
            openURL: { _ in }
        )
        var initialSnapshot = StudioRecorderSnapshot()
        initialSnapshot.route = .studio
        initialSnapshot.captureState = .ready
        let model = StudioRecorderModel(
            coordinator: nil,
            permissionCenter: center,
            initialSnapshot: initialSnapshot
        )

        await model.launch()
        XCTAssertEqual(model.snapshot.permissionSnapshot.screenRecording, .denied)

        screenIsGranted = true
        await model.appBecameActive()

        XCTAssertEqual(model.snapshot.permissionSnapshot.screenRecording, .granted)

        microphoneStatus = .denied
        await model.appBecameActive()
        XCTAssertEqual(model.snapshot.requiredCapturePermission, .microphone)

        XCTAssertEqual(model.send(.recordWithoutMicrophone), .microphoneDisabledForDraft)
        XCTAssertNil(model.snapshot.requiredCapturePermission)

        screenIsGranted = false
        await model.appBecameActive()
        XCTAssertEqual(model.snapshot.requiredCapturePermission, .screenRecording)
    }

    func testCaptureReadinessRequiresScreenAndOnlyRequiresMicrophoneWhenEnabled() {
        var snapshot = StudioRecorderSnapshot()
        snapshot.permissionSnapshot = PermissionSnapshot(
            screenRecording: .granted,
            microphone: .denied
        )

        XCTAssertEqual(snapshot.requiredCapturePermission, .microphone)
        XCTAssertTrue(snapshot.showsCaptureRepair)

        snapshot.capturesMicrophone = false

        XCTAssertNil(snapshot.requiredCapturePermission)
        XCTAssertFalse(snapshot.showsCaptureRepair)

        snapshot.permissionSnapshot = PermissionSnapshot(
            screenRecording: .denied,
            microphone: .granted
        )

        XCTAssertEqual(snapshot.requiredCapturePermission, .screenRecording)
    }

    func testRecordWithoutMicrophoneChangesOnlyTheCurrentDraft() {
        var snapshot = StudioRecorderSnapshot()
        snapshot.route = .studio
        snapshot.captureState = .ready
        snapshot.capturesMicrophone = true
        snapshot.permissionSnapshot = PermissionSnapshot(
            screenRecording: .granted,
            microphone: .denied
        )
        let model = StudioRecorderModel(coordinator: nil, initialSnapshot: snapshot)

        XCTAssertEqual(model.send(.recordWithoutMicrophone), .microphoneDisabledForDraft)
        XCTAssertFalse(model.snapshot.capturesMicrophone)
        XCTAssertNil(model.snapshot.requiredCapturePermission)

        var readySnapshot = model.snapshot
        readySnapshot.captureState = .ready
        readySnapshot.availableDisplays = [AvailableDisplay(id: 7, title: "Test Display", pixelSize: .zero)]
        readySnapshot.selectedDisplayIDs = [7]
        let readyModel = StudioRecorderModel(coordinator: nil, initialSnapshot: readySnapshot)

        XCTAssertEqual(
            readyModel.send(.toggleRecording),
            .recordingStartRequested(displayIDs: [7], capturesMicrophone: false)
        )
    }

    func testRecordWithoutMicrophoneCannotMutateAnActiveSession() {
        var snapshot = StudioRecorderSnapshot()
        snapshot.route = .studio
        snapshot.captureState = .recording
        snapshot.capturesMicrophone = true
        let model = StudioRecorderModel(coordinator: nil, initialSnapshot: snapshot)

        XCTAssertEqual(model.send(.recordWithoutMicrophone), .ignored)
        XCTAssertTrue(model.snapshot.capturesMicrophone)
    }

    func testRecordCommandIsBlockedByARequiredPermission() {
        var snapshot = StudioRecorderSnapshot()
        snapshot.route = .studio
        snapshot.captureState = .ready
        snapshot.permissionSnapshot = PermissionSnapshot(
            screenRecording: .denied,
            microphone: .granted
        )
        snapshot.availableDisplays = [AvailableDisplay(id: 7, title: "Test Display", pixelSize: .zero)]
        snapshot.selectedDisplayIDs = [7]
        let model = StudioRecorderModel(coordinator: nil, initialSnapshot: snapshot)

        XCTAssertEqual(model.send(.toggleRecording), .ignored)
        XCTAssertFalse(model.snapshot.isCaptureCommandInFlight)
    }

    func testProjectsRemainBrowsableWhenCapturePermissionIsDenied() {
        var snapshot = StudioRecorderSnapshot()
        snapshot.route = .studio
        snapshot.permissionSnapshot = PermissionSnapshot(
            screenRecording: .denied,
            microphone: .denied
        )
        let model = StudioRecorderModel(coordinator: nil, initialSnapshot: snapshot)

        XCTAssertEqual(model.send(.selectRoute(.projects)), .routeChanged(.projects))
        XCTAssertEqual(model.snapshot.route, .projects)
    }

    func testNewRecordingRoutesToStudioAndClearsProjectSelection() {
        var snapshot = StudioRecorderSnapshot()
        snapshot.selectedProjectID = UUID().uuidString
        snapshot.capturesMicrophone = false
        let model = StudioRecorderModel(coordinator: nil, initialSnapshot: snapshot)

        XCTAssertEqual(model.send(.newRecording), .routeChanged(.studio))
        XCTAssertEqual(model.snapshot.route, .studio)
        XCTAssertNil(model.snapshot.selectedProjectID)
        XCTAssertTrue(model.snapshot.capturesMicrophone)
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
        snapshot.permissionSnapshot = PermissionSnapshot(
            screenRecording: .granted,
            microphone: .granted
        )
        snapshot.availableDisplays = [AvailableDisplay(id: 7, title: "Test Display", pixelSize: .zero)]
        snapshot.selectedDisplayIDs = [7]
        let model = StudioRecorderModel(coordinator: nil, initialSnapshot: snapshot)

        XCTAssertEqual(
            model.send(.toggleRecording),
            .recordingStartRequested(displayIDs: [7], capturesMicrophone: true)
        )
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
