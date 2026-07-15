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

        guard case .recordingStartRequested(let request) = readyModel.send(.toggleRecording) else {
            return XCTFail("Expected a Capture Request")
        }
        XCTAssertEqual(request.displaySources.map(\.id), [7])
        XCTAssertFalse(request.audio.capturesMicrophone)
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
        snapshot.availableMicrophones = [AvailableMicrophone(id: "mic", name: "Microphone", isSystemDefault: true)]
        snapshot.selectedDisplayIDs = [7]
        let model = StudioRecorderModel(coordinator: nil, initialSnapshot: snapshot)

        guard case .recordingStartRequested(let request) = model.send(.toggleRecording) else {
            return XCTFail("Expected a Capture Request")
        }
        XCTAssertEqual(request.displaySources.map(\.id), [7])
        XCTAssertTrue(request.audio.capturesMicrophone)
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

    func testSelectingStudioCreatesAFreshDraftWhenNoneExists() {
        let store = makePreferencesStore()
        var snapshot = StudioRecorderSnapshot()
        snapshot.captureState = .ready
        snapshot.availableDisplays = [AvailableDisplay(id: 7, title: "Display", pixelSize: CGSize(width: 1_920, height: 1_080))]
        snapshot.availableMicrophones = [AvailableMicrophone(id: "mic", name: "Microphone", isSystemDefault: true)]
        let model = StudioRecorderModel(
            coordinator: nil,
            preferencesStore: store,
            initialSnapshot: snapshot
        )

        XCTAssertEqual(model.send(.selectRoute(.studio)), .routeChanged(.studio))
        XCTAssertEqual(model.snapshot.studioDraft?.selectedDisplayIDs, [7])
        XCTAssertEqual(model.send(.setDraftIncludeCursor(false)), .draftChanged)
    }

    func testSettingsChangesDoNotMutateAnExistingDraftAndTheNextDraftUsesThem() {
        let store = makePreferencesStore()
        var snapshot = StudioRecorderSnapshot()
        snapshot.captureState = .ready
        snapshot.availableDisplays = [AvailableDisplay(id: 7, title: "Display", pixelSize: CGSize(width: 1_920, height: 1_080))]
        snapshot.availableMicrophones = [AvailableMicrophone(id: "mic", name: "Microphone", isSystemDefault: true)]
        let model = StudioRecorderModel(
            coordinator: nil,
            permissionCenter: nil,
            preferencesStore: store,
            initialSnapshot: snapshot
        )

        XCTAssertEqual(model.send(.newRecording), .routeChanged(.studio))
        XCTAssertTrue(model.snapshot.studioDraft?.capturesMicrophone == true)

        XCTAssertEqual(
            model.send(.changePreference(.capturesMicrophone(false))),
            .preferenceChanged
        )
        XCTAssertFalse(store.preferences.audio.capturesMicrophone)
        XCTAssertTrue(model.snapshot.studioDraft?.capturesMicrophone == true)

        XCTAssertEqual(model.send(.newRecording), .routeChanged(.studio))
        XCTAssertFalse(model.snapshot.studioDraft?.capturesMicrophone == true)
    }

    func testCaptureAudioAndStorageSettingsLockFromPreparingThroughFinalizing() {
        for state in [RecordingState.preparing, .recording, .stopping] {
            let store = makePreferencesStore()
            var snapshot = StudioRecorderSnapshot()
            snapshot.captureState = state
            let model = StudioRecorderModel(
                coordinator: nil,
                permissionCenter: nil,
                preferencesStore: store,
                initialSnapshot: snapshot
            )

            XCTAssertTrue(model.snapshot.areRecordingSettingsLocked)
            XCTAssertEqual(model.send(.changePreference(.includeCursor(false))), .ignored)
            XCTAssertTrue(store.preferences.capture.includeCursor)
            XCTAssertEqual(model.send(.changePreference(.appearance(.dark))), .preferenceChanged)
            XCTAssertEqual(store.preferences.appearance, .dark)
        }
    }

    func testRecordIntentFreezesOneRequestAndLocksItAgainstSettingsChanges() throws {
        let store = makePreferencesStore()
        var snapshot = StudioRecorderSnapshot()
        snapshot.route = .studio
        snapshot.captureState = .ready
        snapshot.permissionSnapshot = PermissionSnapshot(screenRecording: .granted, microphone: .granted)
        snapshot.availableDisplays = [AvailableDisplay(id: 7, title: "Display", pixelSize: CGSize(width: 1_920, height: 1_080))]
        snapshot.availableMicrophones = [AvailableMicrophone(id: "mic", name: "Microphone", isSystemDefault: true)]
        let model = StudioRecorderModel(
            coordinator: nil,
            permissionCenter: nil,
            preferencesStore: store,
            initialSnapshot: snapshot
        )
        model.send(.newRecording)

        guard case .recordingStartRequested(let request) = model.send(.toggleRecording) else {
            return XCTFail("Expected a frozen Capture Request")
        }

        XCTAssertEqual(model.snapshot.activeCaptureRequest, request)
        XCTAssertTrue(model.snapshot.areRecordingSettingsLocked)
        XCTAssertEqual(model.send(.toggleRecording), .ignored)
        XCTAssertEqual(model.send(.changePreference(.capturesMicrophone(false))), .ignored)
        XCTAssertTrue(request.audio.capturesMicrophone)
        XCTAssertTrue(store.preferences.audio.capturesMicrophone)
    }

    func testDraftOverridesNeverRewriteSavedDefaults() {
        let store = makePreferencesStore()
        var snapshot = StudioRecorderSnapshot()
        snapshot.captureState = .ready
        snapshot.availableDisplays = [AvailableDisplay(id: 7, title: "Display", pixelSize: CGSize(width: 1_920, height: 1_080))]
        snapshot.availableMicrophones = [AvailableMicrophone(id: "mic", name: "Microphone", isSystemDefault: true)]
        let model = StudioRecorderModel(
            coordinator: nil,
            preferencesStore: store,
            initialSnapshot: snapshot
        )
        model.send(.newRecording)

        XCTAssertEqual(model.send(.setDraftIncludeCursor(false)), .draftChanged)
        XCTAssertEqual(model.send(.setDraftCapturesSystemAudio(false)), .draftChanged)
        XCTAssertFalse(model.snapshot.studioDraft?.includeCursor == true)
        XCTAssertFalse(model.snapshot.studioDraft?.capturesSystemAudio == true)
        XCTAssertTrue(store.preferences.capture.includeCursor)
        XCTAssertTrue(store.preferences.audio.capturesSystemAudio)
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

    private func makePreferencesStore() -> PreferencesStore {
        let suiteName = "StudioRecorderModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return PreferencesStore(
            defaults: defaults,
            defaultDestination: URL(filePath: "/tmp/Movies/Studio Recorder", directoryHint: .isDirectory),
            destinationIsWritable: { _ in true }
        )
    }
}
