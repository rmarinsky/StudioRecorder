import AVFoundation
import XCTest
@testable import StudioRecorder

@MainActor
final class StudioRecorderModelTests: XCTestCase {
    func testCaptureTransitionShowsPreparationOnlyForARequestedRecording() {
        var snapshot = StudioRecorderSnapshot()
        snapshot.captureState = .preparing
        XCTAssertNil(snapshot.captureTransitionPresentation)

        snapshot.beginCaptureCommand(.start)
        snapshot.applyCaptureState(.preparing)

        XCTAssertEqual(
            snapshot.captureTransitionPresentation,
            CaptureTransitionPresentation(
                kind: .preparing,
                title: "Preparing recording",
                detail: "Starting camera and screen capture…",
                progress: nil
            )
        )
    }

    func testCaptureTransitionShowsLiveSavingProgress() {
        var snapshot = StudioRecorderSnapshot()
        snapshot.captureState = .stopping
        snapshot.finalizationProgress = RecordingFinalizationProgress(
            fraction: 0.64,
            phase: "Rendering final video…"
        )

        XCTAssertEqual(
            snapshot.captureTransitionPresentation,
            CaptureTransitionPresentation(
                kind: .saving,
                title: "Saving recording",
                detail: "Rendering final video…",
                progress: 0.64
            )
        )
    }

    func testRecordingControlsOnlySwitchScenesForAnActiveStableLocalRecording() {
        var snapshot = StudioRecorderSnapshot()
        snapshot.captureState = .ready
        XCTAssertFalse(RecordingControlPanelPolicy.canSwitchScenes(snapshot))

        snapshot.captureState = .recording
        snapshot.activeCaptureRequest = CaptureRequest(
            id: UUID(),
            createdAt: .now,
            displaySources: [],
            audio: AudioCaptureSnapshot(
                capturesSystemAudio: false,
                capturesMicrophone: false,
                microphone: nil,
                primaryAudioDisplayID: nil,
                excludesStudioRecorderAudio: true
            ),
            profile: CaptureProfileSnapshot(
                frameRate: 30,
                codecPolicy: .automatic,
                includeCursor: true,
                excludeStudioRecorder: true,
                programResolutionTarget: "1920x1080"
            ),
            storage: StorageCaptureSnapshot(
                destinationURL: nil,
                destinationBookmarkID: "test",
                fallbackPath: "/tmp"
            )
        )
        XCTAssertTrue(RecordingControlPanelPolicy.canSwitchScenes(snapshot))

        snapshot.beginCaptureCommand(.pause)
        XCTAssertFalse(RecordingControlPanelPolicy.canSwitchScenes(snapshot))
    }

    func testLatestAsyncTaskQueueBoundsPendingScreenFrames() async {
        let queue = LatestAsyncTaskQueue()
        let values = LatestValueRecorder()
        queue.enqueue {
            await values.appendAndWaitForRelease(1)
        }
        while !(await values.didStartFirstValue) {
            await Task.yield()
        }
        queue.enqueue {
            await values.append(2)
        }
        queue.enqueue {
            await values.append(3)
        }
        await values.releaseFirstValue()

        await queue.flush()

        let recorded = await values.values
        XCTAssertEqual(recorded, [1, 3])
    }

    func testLatestAsyncTaskQueueDoesNotLetIdleMetadataReplaceAPendingCompleteFrame() async {
        let queue = LatestAsyncTaskQueue()
        let values = LatestValueRecorder()
        queue.enqueue(priority: .frame) {
            await values.appendAndWaitForRelease(1)
        }
        while !(await values.didStartFirstValue) {
            await Task.yield()
        }
        queue.enqueue(priority: .frame) {
            await values.append(2)
        }
        queue.enqueue(priority: .idle) {
            await values.append(3)
        }
        await values.releaseFirstValue()

        await queue.flush()

        let recorded = await values.values
        XCTAssertEqual(recorded, [1, 2])
    }

    func testSavedSceneSwitchReturnsOneOrderedEventForAllDeliveryConsumers() throws {
        var snapshot = StudioRecorderSnapshot()
        snapshot.route = .studio
        snapshot.captureState = .ready
        snapshot.studioDraft = PreferencesStore().makeStudioDraft(
            displays: [],
            microphones: [],
            cameras: []
        )
        let model = StudioRecorderModel(coordinator: nil, initialSnapshot: snapshot)
        var first = CapturePresentationSnapshot.default
        first.name = "First"
        var second = first
        second.name = "Second"

        guard case .sceneSwitchAccepted(let firstEvent) = model.send(.switchScene(first)) else {
            return XCTFail("The first saved scene should produce one accepted switch event.")
        }
        guard case .sceneSwitchAccepted(let secondEvent) = model.send(.switchScene(second)) else {
            return XCTFail("The second saved scene should produce one accepted switch event.")
        }

        XCTAssertEqual(firstEvent.presentation, first.validated())
        XCTAssertEqual(secondEvent.presentation, second.validated())
        XCTAssertGreaterThan(secondEvent.sequence, firstEvent.sequence)
        XCTAssertEqual(model.snapshot.studioDraft?.presentation, second.validated())
    }

    func testSavedSceneSwitchRestoresDisplayCameraAndAudioSourceState() {
        let displays = [
            AvailableDisplay(id: 7, title: "Display", pixelSize: CGSize(width: 1_920, height: 1_080)),
        ]
        let microphones = [AvailableMicrophone(id: "mic-1", name: "Studio Mic", isSystemDefault: true)]
        let cameras = [
            AvailableCamera(id: "camera-1", name: "FaceTime Camera"),
            AvailableCamera(id: "camera-2", name: "iPhone Camera"),
        ]
        var snapshot = StudioRecorderSnapshot()
        snapshot.route = .studio
        snapshot.captureState = .ready
        snapshot.permissionSnapshot = PermissionSnapshot(
            screenRecording: .granted,
            microphone: .granted,
            camera: .granted
        )
        snapshot.availableDisplays = displays
        snapshot.availableMicrophones = microphones
        snapshot.availableCameras = cameras
        snapshot.studioDraft = PreferencesStore().makeStudioDraft(
            displays: displays,
            microphones: microphones,
            cameras: cameras
        )
        snapshot.selectedDisplayIDs = [7]
        let model = StudioRecorderModel(coordinator: nil, initialSnapshot: snapshot)
        var presentation = CapturePresentationSnapshot.default
        presentation.name = "Full Camera"
        presentation.screen.isVisible = false
        var configuration = StudioProfileConfiguration.desktop
        configuration.frameRate = 60
        configuration.cameraDeviceID = "camera-2"
        configuration.microphoneDeviceID = "mic-1"
        configuration.displayIDs = [7]
        let scene = StudioScenePreset(
            presentation: presentation,
            sources: StudioSceneSourceState(
                selectedDisplayIDs: [],
                capturesSystemAudio: false,
                capturesMicrophone: false,
                capturesCamera: true
            ),
            configuration: configuration
        )

        guard case .sceneSwitchAccepted = model.send(.switchScenePreset(scene)) else {
            return XCTFail("The saved scene should be applied.")
        }

        XCTAssertEqual(model.snapshot.selectedDisplayIDs, [])
        XCTAssertTrue(model.snapshot.capturesCamera)
        XCTAssertFalse(model.snapshot.capturesMicrophone)
        XCTAssertFalse(model.snapshot.studioDraft?.capturesSystemAudio ?? true)
        XCTAssertEqual(model.snapshot.studioDraft?.frameRate, 60)
        XCTAssertEqual(model.snapshot.studioDraft?.cameraDeviceID, "camera-2")
        XCTAssertEqual(model.snapshot.studioDraft?.microphoneDeviceID, "mic-1")
        XCTAssertEqual(model.snapshot.studioDraft?.presentation.resolvedName, "Full Camera")
    }

    func testLiveSceneStaysVisibleWhileRecording() {
        XCTAssertTrue(LiveScenePolicy.shouldRun(route: .studio, captureState: .ready))
        XCTAssertTrue(LiveScenePolicy.shouldRun(route: .studio, captureState: .preparing))
        XCTAssertTrue(LiveScenePolicy.shouldRun(route: .studio, captureState: .recording))
        XCTAssertTrue(LiveScenePolicy.shouldRun(route: .studio, captureState: .paused))
        XCTAssertTrue(LiveScenePolicy.shouldRun(route: .studio, captureState: .stopping))
        XCTAssertFalse(LiveScenePolicy.shouldRun(route: .projects, captureState: .recording))
        XCTAssertFalse(LiveScenePolicy.shouldRun(route: .settings, captureState: .recording))
        XCTAssertTrue(LiveScenePolicy.shouldRunDraftCamera(route: .studio, captureState: .recording))
        XCTAssertTrue(LiveScenePolicy.shouldPreserveCameraSession(captureState: .recording))
        XCTAssertTrue(LiveScenePolicy.shouldPreserveCameraSession(captureState: .paused))
        XCTAssertFalse(LiveScenePolicy.shouldPreserveCameraSession(captureState: .ready))
    }

    func testPauseCommandWaitsForRuntimeStateAndThenResumes() {
        var snapshot = StudioRecorderSnapshot()
        snapshot.route = .studio
        snapshot.captureState = .recording
        let model = StudioRecorderModel(coordinator: nil, initialSnapshot: snapshot)

        XCTAssertEqual(model.send(.toggleRecordingPause), .recordingPauseRequested)
        XCTAssertTrue(model.snapshot.isCaptureCommandInFlight)
        XCTAssertEqual(model.send(.toggleRecordingPause), .ignored)

        var paused = model.snapshot
        paused.applyCaptureState(.recording)
        XCTAssertTrue(paused.isCaptureCommandInFlight)
        paused.applyCaptureState(.paused)
        XCTAssertFalse(paused.isCaptureCommandInFlight)

        let pausedModel = StudioRecorderModel(coordinator: nil, initialSnapshot: paused)
        XCTAssertEqual(pausedModel.send(.toggleRecordingPause), .recordingResumeRequested)
        XCTAssertTrue(pausedModel.snapshot.isCaptureCommandInFlight)

        var resumed = pausedModel.snapshot
        resumed.applyCaptureState(.paused)
        XCTAssertTrue(resumed.isCaptureCommandInFlight)
        resumed.applyCaptureState(.recording)
        XCTAssertFalse(resumed.isCaptureCommandInFlight)
    }

    func testStopCommandWorksWhileRecordingIsPaused() {
        var snapshot = StudioRecorderSnapshot()
        snapshot.captureState = .paused
        let model = StudioRecorderModel(coordinator: nil, initialSnapshot: snapshot)

        XCTAssertEqual(model.send(.toggleRecording), .recordingStopRequested)
        XCTAssertTrue(model.snapshot.isCaptureCommandInFlight)
    }

    func testSettingsIsAnInWindowRoute() {
        let model = StudioRecorderModel(coordinator: nil, initialSnapshot: StudioRecorderSnapshot())

        XCTAssertEqual(model.send(.selectRoute(.settings)), .routeChanged(.settings))
        XCTAssertEqual(model.snapshot.route, .settings)
    }

    func testPresentationCleanupCanRestoreAnIdleDraftAfterLeavingStudio() throws {
        var snapshot = StudioRecorderSnapshot()
        snapshot.route = .settings
        snapshot.captureState = .ready
        snapshot.studioDraft = PreferencesStore().makeStudioDraft(
            displays: [],
            microphones: [],
            cameras: []
        )
        let model = StudioRecorderModel(coordinator: nil, initialSnapshot: snapshot)
        var presentation = try XCTUnwrap(snapshot.studioDraft?.presentation)
        presentation.framing = ScreenFramingSnapshot(mode: .fullDisplay)

        XCTAssertEqual(model.send(.setDraftPresentation(presentation)), .draftChanged)
        XCTAssertEqual(model.snapshot.studioDraft?.presentation.framing.mode, .fullDisplay)
    }

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

    func testCameraPermissionCanBeRepairedOrDisabledForOnlyTheCurrentDraft() throws {
        var snapshot = StudioRecorderSnapshot()
        snapshot.route = .studio
        snapshot.captureState = .ready
        snapshot.capturesMicrophone = false
        snapshot.capturesCamera = true
        snapshot.permissionSnapshot = PermissionSnapshot(
            screenRecording: .granted,
            microphone: .granted,
            camera: .denied
        )
        snapshot.availableCameras = [AvailableCamera(id: "camera-1", name: "FaceTime HD Camera")]
        snapshot.studioDraft = PreferencesStore().makeStudioDraft(
            displays: [],
            microphones: [],
            cameras: snapshot.availableCameras
        )
        let model = StudioRecorderModel(coordinator: nil, initialSnapshot: snapshot)

        let presentation = try XCTUnwrap(model.snapshot.permissionRepairPresentation)
        XCTAssertEqual(presentation.permission, .camera)
        XCTAssertEqual(presentation.title, "Allow Camera")
        XCTAssertEqual(
            presentation.actions,
            [.openSystemSettings, .recordWithoutCamera, .checkAgain, .browseProjects]
        )

        XCTAssertEqual(model.send(.recordWithoutCamera), .cameraDisabledForDraft)
        XCTAssertFalse(model.snapshot.capturesCamera)
        XCTAssertFalse(model.snapshot.studioDraft?.capturesCamera ?? true)
        XCTAssertNil(model.snapshot.requiredCapturePermission)
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

    func testProjectDetailCanBeOpenedAndClosedWithoutChangingTheProjectsRoute() {
        let project = interruptedProject()
        var snapshot = StudioRecorderSnapshot()
        snapshot.projects = [project]
        let model = StudioRecorderModel(coordinator: nil, initialSnapshot: snapshot)

        XCTAssertEqual(model.send(.openProject(project.id)), .projectOpened(project.id))
        XCTAssertEqual(model.snapshot.selectedProjectID, project.id)

        XCTAssertEqual(model.send(.closeProject), .projectClosed)
        XCTAssertNil(model.snapshot.selectedProjectID)
        XCTAssertEqual(model.snapshot.route, .projects)
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
        XCTAssertTrue(synchronized.isCaptureCommandInFlight)
        synchronized.applyCaptureState(.recording)
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

    func testFrameRateChangeUpdatesTheCurrentDraftWithoutChangingDefaults() {
        let store = makePreferencesStore()
        var snapshot = StudioRecorderSnapshot()
        snapshot.captureState = .ready
        snapshot.route = .studio
        snapshot.studioDraft = store.makeStudioDraft(displays: [], microphones: [])
        let model = StudioRecorderModel(
            coordinator: nil,
            preferencesStore: store,
            initialSnapshot: snapshot
        )

        XCTAssertEqual(model.send(.setDraftFrameRate(60)), .draftChanged)
        XCTAssertEqual(model.snapshot.studioDraft?.frameRate, 60)
        XCTAssertEqual(store.preferences.capture.frameRate, 30)
    }

    func test4KPresentationCapsTheCurrentDraftAtThirtyFPS() throws {
        let store = makePreferencesStore()
        var snapshot = StudioRecorderSnapshot()
        snapshot.captureState = .ready
        snapshot.route = .studio
        snapshot.studioDraft = store.makeStudioDraft(displays: [], microphones: [])
        let model = StudioRecorderModel(
            coordinator: nil,
            preferencesStore: store,
            initialSnapshot: snapshot
        )

        XCTAssertEqual(model.send(.setDraftFrameRate(60)), .draftChanged)
        var presentation = try XCTUnwrap(model.snapshot.studioDraft?.presentation)
        presentation.canvas = CaptureCanvasSnapshot(preset: .ultraHD)

        XCTAssertEqual(model.send(.setDraftPresentation(presentation)), .draftChanged)
        XCTAssertEqual(model.snapshot.studioDraft?.frameRate, 30)
    }

    func test4KProfileSceneCapsTheCurrentDraftAtThirtyFPS() {
        var snapshot = StudioRecorderSnapshot()
        snapshot.captureState = .ready
        snapshot.route = .studio
        snapshot.studioDraft = PreferencesStore().makeStudioDraft(displays: [], microphones: [])
        let model = StudioRecorderModel(coordinator: nil, initialSnapshot: snapshot)

        var presentation = CapturePresentationSnapshot.default
        presentation.canvas = CaptureCanvasSnapshot(preset: .ultraHD)
        var configuration = StudioProfileConfiguration.desktop
        configuration.frameRate = 60
        let scene = StudioScenePreset(presentation: presentation, configuration: configuration)

        XCTAssertEqual(model.send(.applyProfile(configuration, scene)), .draftChanged)
        XCTAssertEqual(model.snapshot.studioDraft?.frameRate, 30)
    }

    func testCodecChangeUpdatesTheCurrentDraftWithoutChangingDefaults() {
        let store = makePreferencesStore()
        var snapshot = StudioRecorderSnapshot()
        snapshot.captureState = .ready
        snapshot.route = .studio
        snapshot.studioDraft = store.makeStudioDraft(displays: [], microphones: [])
        let model = StudioRecorderModel(
            coordinator: nil,
            preferencesStore: store,
            initialSnapshot: snapshot
        )

        XCTAssertEqual(model.send(.setDraftCodecPolicy(.h264)), .draftChanged)
        XCTAssertEqual(model.snapshot.studioDraft?.codecPolicy, .h264)
        XCTAssertEqual(store.preferences.capture.codecPolicy, .automatic)
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
        for state in [RecordingState.preparing, .recording, .paused, .stopping] {
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

    func testStreamSafetyArchiveFreezesProgramOnlyRequestWithoutChangingDraftPreference() throws {
        let store = makePreferencesStore()
        var snapshot = StudioRecorderSnapshot()
        snapshot.route = .studio
        snapshot.captureState = .ready
        snapshot.permissionSnapshot = PermissionSnapshot(screenRecording: .granted, microphone: .granted)
        snapshot.availableDisplays = [AvailableDisplay(
            id: 7,
            title: "Display",
            pixelSize: CGSize(width: 3_840, height: 2_160)
        )]
        snapshot.availableMicrophones = [AvailableMicrophone(
            id: "mic",
            name: "Microphone",
            isSystemDefault: true
        )]
        let model = StudioRecorderModel(
            coordinator: nil,
            permissionCenter: nil,
            preferencesStore: store,
            initialSnapshot: snapshot
        )
        model.send(.newRecording)
        model.send(.setSelectedDisplayIDs([7]))

        let request = try XCTUnwrap(model.makeCaptureRequest(retentionPolicy: .programOnly))

        XCTAssertEqual(request.storage.resolvedRetentionPolicy, .programOnly)
        XCTAssertEqual(model.snapshot.studioDraft?.retentionPolicy, .editableTracks)
        XCTAssertNil(model.snapshot.activeCaptureRequest)
        XCTAssertFalse(model.snapshot.isCaptureCommandInFlight)
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
            recoveryReport: RecordingProjectRecoveryReport(tracks: [], diagnostics: ["Interrupted"]),
            presentation: nil,
            primaryAudioDisplayID: nil
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

private actor LatestValueRecorder {
    private(set) var values: [Int] = []
    private(set) var didStartFirstValue = false
    private var firstValueContinuation: CheckedContinuation<Void, Never>?

    func appendAndWaitForRelease(_ value: Int) async {
        values.append(value)
        didStartFirstValue = true
        await withCheckedContinuation { continuation in
            firstValueContinuation = continuation
        }
    }

    func append(_ value: Int) {
        values.append(value)
    }

    func releaseFirstValue() {
        firstValueContinuation?.resume()
        firstValueContinuation = nil
    }
}
