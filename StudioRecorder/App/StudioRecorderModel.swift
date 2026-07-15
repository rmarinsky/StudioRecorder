import AppKit
import AVFoundation
import Combine
import CoreGraphics
import Foundation

enum CapturePermission: Equatable {
    case screenRecording
    case microphone
    case camera
}

enum PermissionAccessState: Equatable {
    case checking
    case notDetermined
    case denied
    case granted
    case grantedButRelaunchRequired
    case unavailable(String)

    var isGranted: Bool { self == .granted }
}

struct PermissionSnapshot: Equatable {
    var screenRecording: PermissionAccessState
    var microphone: PermissionAccessState
    var camera: PermissionAccessState

    init(
        screenRecording: PermissionAccessState,
        microphone: PermissionAccessState,
        camera: PermissionAccessState = .granted
    ) {
        self.screenRecording = screenRecording
        self.microphone = microphone
        self.camera = camera
    }

    static let checking = PermissionSnapshot(screenRecording: .checking, microphone: .checking, camera: .checking)

    func requiredPermission(capturesMicrophone: Bool, capturesCamera: Bool = false) -> CapturePermission? {
        if !screenRecording.isGranted { return .screenRecording }
        if capturesMicrophone, !microphone.isGranted { return .microphone }
        if capturesCamera, !camera.isGranted { return .camera }
        return nil
    }
}

@MainActor
final class PermissionCenter {
    typealias ScreenPreflight = () -> Bool
    typealias ScreenRequest = () -> Bool
    typealias MicrophoneStatus = () -> AVAuthorizationStatus
    typealias MicrophoneRequest = () async -> Bool
    typealias CameraStatus = () -> AVAuthorizationStatus
    typealias CameraRequest = () async -> Bool
    typealias OpenURL = (URL) -> Void

    private let screenPreflight: ScreenPreflight
    private let screenRequest: ScreenRequest
    private let microphoneStatus: MicrophoneStatus
    private let microphoneRequest: MicrophoneRequest
    private let cameraStatus: CameraStatus
    private let cameraRequest: CameraRequest
    private let openURL: OpenURL
    private var screenGrantAcceptedInCurrentProcess = false

    convenience init() {
        self.init(
            screenPreflight: { CGPreflightScreenCaptureAccess() },
            screenRequest: { CGRequestScreenCaptureAccess() },
            microphoneStatus: { AVCaptureDevice.authorizationStatus(for: .audio) },
            microphoneRequest: { await AVCaptureDevice.requestAccess(for: .audio) },
            cameraStatus: { AVCaptureDevice.authorizationStatus(for: .video) },
            cameraRequest: { await AVCaptureDevice.requestAccess(for: .video) },
            openURL: { NSWorkspace.shared.open($0) }
        )
    }

    init(
        screenPreflight: @escaping ScreenPreflight,
        screenRequest: @escaping ScreenRequest,
        microphoneStatus: @escaping MicrophoneStatus,
        microphoneRequest: @escaping MicrophoneRequest,
        cameraStatus: @escaping CameraStatus = { .authorized },
        cameraRequest: @escaping CameraRequest = { true },
        openURL: @escaping OpenURL
    ) {
        self.screenPreflight = screenPreflight
        self.screenRequest = screenRequest
        self.microphoneStatus = microphoneStatus
        self.microphoneRequest = microphoneRequest
        self.cameraStatus = cameraStatus
        self.cameraRequest = cameraRequest
        self.openURL = openURL
    }

    func refresh() async -> PermissionSnapshot {
        PermissionSnapshot(
            screenRecording: screenAccessState(),
            microphone: microphoneAccessState(),
            camera: cameraAccessState()
        )
    }

    func request(_ permission: CapturePermission) async {
        switch permission {
        case .screenRecording:
            screenGrantAcceptedInCurrentProcess = screenRequest()
        case .microphone:
            guard microphoneAccessState() == .notDetermined else { return }
            _ = await microphoneRequest()
        case .camera:
            guard cameraAccessState() == .notDetermined else { return }
            _ = await cameraRequest()
        }
    }

    func openSystemSettings(for permission: CapturePermission) {
        let pane: String
        switch permission {
        case .screenRecording:
            pane = "Privacy_ScreenCapture"
        case .microphone:
            pane = "Privacy_Microphone"
        case .camera:
            pane = "Privacy_Camera"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else {
            return
        }
        openURL(url)
    }

    private func screenAccessState() -> PermissionAccessState {
        if screenPreflight() { return .granted }
        return screenGrantAcceptedInCurrentProcess ? .grantedButRelaunchRequired : .denied
    }

    private func microphoneAccessState() -> PermissionAccessState {
        accessState(for: microphoneStatus(), restrictedMessage: "Microphone access is restricted.")
    }

    private func cameraAccessState() -> PermissionAccessState {
        accessState(for: cameraStatus(), restrictedMessage: "Camera access is restricted.")
    }

    private func accessState(for status: AVAuthorizationStatus, restrictedMessage: String) -> PermissionAccessState {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .granted
        case .restricted: return .unavailable(restrictedMessage)
        @unknown default: return .unavailable("Capture permission status is unavailable.")
        }
    }
}

enum MainRoute: Hashable {
    case projects
    case studio
    case recovery
}

enum LaunchPhase: Equatable {
    case checking
    case ready
    case needsCaptureRepair(PermissionSnapshot)
}

enum AppIntent: Equatable {
    case newRecording
    case selectRoute(MainRoute)
    case openProject(String)
    case closeProject
    case focusProjectSearch
    case toggleRecording
    case setSelectedDisplayIDs(Set<UInt32>)
    case setCapturesMicrophone(Bool)
    case setCapturesCamera(Bool)
    case setDraftCameraDeviceID(String?)
    case setDraftCapturesSystemAudio(Bool)
    case setDraftMicrophoneDeviceID(String?)
    case setDraftIncludeCursor(Bool)
    case setDraftExcludeStudioRecorder(Bool)
    case setDraftExcludeStudioRecorderAudio(Bool)
    case setDraftPresentation(CapturePresentationSnapshot)
    case setDraftRetentionPolicy(MediaRetentionPolicy)
    case recordWithoutMicrophone
    case recordWithoutCamera
    case changePreference(PreferenceChange)
    case setProjectDestination(URL)
}

enum PreferenceChange: Equatable {
    case appearance(AppearancePreference)
    case codecPolicy(RecordingCodecPolicy)
    case includeCursor(Bool)
    case excludeStudioRecorder(Bool)
    case capturesSystemAudio(Bool)
    case capturesMicrophone(Bool)
    case microphoneDeviceID(String?)
    case excludeStudioRecorderAudio(Bool)
}

enum AppIntentResult: Equatable {
    case ignored
    case routeChanged(MainRoute)
    case projectOpened(String)
    case projectClosed
    case projectSearchRequested
    case recordingStartRequested(CaptureRequest)
    case recordingStopRequested
    case displaySelectionChanged
    case microphoneCaptureChanged
    case microphoneDisabledForDraft
    case cameraDisabledForDraft
    case draftChanged
    case preferenceChanged
    case preferenceChangeFailed(String)
}

enum PendingCaptureCommand: Equatable {
    case start
    case stop
}

struct StudioRecorderSnapshot: Equatable {
    var route: MainRoute = .projects
    var launchPhase: LaunchPhase = .checking
    var selectedProjectID: String?
    var captureState: RecordingState = .preparing
    var availableDisplays: [AvailableDisplay] = []
    var availableMicrophones: [AvailableMicrophone] = []
    var availableCameras: [AvailableCamera] = []
    var projects: [RecordingProjectSnapshot] = []
    var interruptedProjects: [RecordingProjectSnapshot] = []
    var selectedDisplayIDs: Set<UInt32> = []
    var permissionSnapshot: PermissionSnapshot = .checking
    var capturesMicrophone = true
    var capturesCamera = false
    var studioDraft: StudioDraft?
    var activeCaptureRequest: CaptureRequest?
    var finalizationWarning: String?
    private(set) var pendingCaptureCommand: PendingCaptureCommand?

    var isCaptureCommandInFlight: Bool { pendingCaptureCommand != nil }
    var areRecordingSettingsLocked: Bool {
        if pendingCaptureCommand == .start || activeCaptureRequest != nil { return true }
        return switch captureState {
        case .preparing, .recording, .stopping: true
        case .ready, .failed: false
        }
    }
    var requiredCapturePermission: CapturePermission? {
        permissionSnapshot.requiredPermission(capturesMicrophone: capturesMicrophone, capturesCamera: capturesCamera)
    }
    var showsCaptureRepair: Bool {
        guard requiredCapturePermission != nil else { return false }
        return captureState != .recording && captureState != .stopping
    }
    var draftValidationIssues: [StudioDraftValidationIssue] {
        studioDraft?.validationIssues(
            displays: availableDisplays,
            microphones: availableMicrophones,
            cameras: availableCameras,
            permissions: permissionSnapshot
        ) ?? [.noDisplaySelected]
    }

    mutating func beginCaptureCommand(_ command: PendingCaptureCommand) {
        pendingCaptureCommand = command
    }

    mutating func applyCaptureState(_ state: RecordingState) {
        captureState = state

        switch (pendingCaptureCommand, state) {
        case (.start?, .ready), (.stop?, .recording):
            break
        case (.some, _):
            pendingCaptureCommand = nil
        case (.none, _):
            break
        }
    }
}

enum PermissionRepairAction: Equatable {
    case requestAccess
    case openSystemSettings
    case recordWithoutMicrophone
    case recordWithoutCamera
    case checkAgain
    case browseProjects
}

struct PermissionRepairPresentation: Equatable {
    let permission: CapturePermission
    let state: PermissionAccessState
    let title: String
    let explanation: String
    let detail: String
    let screenStatusLabel: String
    let microphoneStatusLabel: String
    let cameraStatusLabel: String
    let showsLoadingSkeleton: Bool
    let actions: [PermissionRepairAction]
}

extension StudioRecorderSnapshot {
    var permissionRepairPresentation: PermissionRepairPresentation? {
        guard showsCaptureRepair, let permission = requiredCapturePermission else { return nil }
        let state: PermissionAccessState = switch permission {
        case .screenRecording: permissionSnapshot.screenRecording
        case .microphone: permissionSnapshot.microphone
        case .camera: permissionSnapshot.camera
        }
        let title: String = switch (permission, state) {
        case (.screenRecording, .grantedButRelaunchRequired): "Relaunch Studio Recorder"
        case (.screenRecording, _): "Allow Screen Recording"
        case (.microphone, .notDetermined): "Allow Microphone"
        case (.microphone, _): "Microphone access needs attention"
        case (.camera, .notDetermined): "Allow Camera"
        case (.camera, _): "Allow Camera"
        }
        let explanation: String = switch permission {
        case .screenRecording:
            "Screen Recording is required to discover and record selected displays. Existing projects remain available."
        case .microphone:
            "The current Studio Draft includes microphone capture. Repair access or record this draft without a microphone."
        case .camera:
            "The current Studio Draft includes an independent camera track. Repair access or record this draft without a camera."
        }

        var actions: [PermissionRepairAction] = []
        if state == .checking {
            actions = [.browseProjects]
        } else {
            if state == .notDetermined || (permission == .screenRecording && state == .denied) {
                actions.append(.requestAccess)
            }
            if state == .denied {
                actions.append(.openSystemSettings)
            }
            if permission == .microphone {
                actions.append(.recordWithoutMicrophone)
            }
            if permission == .camera {
                actions.append(.recordWithoutCamera)
            }
            actions.append(contentsOf: [.checkAgain, .browseProjects])
        }

        return PermissionRepairPresentation(
            permission: permission,
            state: state,
            title: title,
            explanation: explanation,
            detail: state.repairDetail,
            screenStatusLabel: permissionSnapshot.screenRecording.statusLabel,
            microphoneStatusLabel: permissionSnapshot.microphone.statusLabel,
            cameraStatusLabel: permissionSnapshot.camera.statusLabel,
            showsLoadingSkeleton: state == .checking,
            actions: actions
        )
    }
}

private extension PermissionAccessState {
    var statusLabel: String {
        switch self {
        case .checking: "Checking"
        case .notDetermined: "Not determined"
        case .denied: "Denied"
        case .granted: "Granted"
        case .grantedButRelaunchRequired: "Granted, relaunch required"
        case .unavailable: "Unavailable"
        }
    }

    var repairDetail: String {
        switch self {
        case .checking: "Studio Recorder is checking the current system status."
        case .notDetermined: "macOS has not received a permission decision yet."
        case .denied: "Open Privacy & Security, then return here. Access refreshes when the app becomes active."
        case .granted: "Access is ready."
        case .grantedButRelaunchRequired: "macOS accepted access, but this app process must be relaunched before capture can begin."
        case .unavailable(let message): message
        }
    }
}

@MainActor
final class StudioRecorderModel: ObservableObject {
    @Published private(set) var snapshot: StudioRecorderSnapshot

    private let coordinator: RecordingCoordinator?
    private let permissionCenter: PermissionCenter?
    private let preferencesStore: PreferencesStore
    private var coordinatorObservation: AnyCancellable?
    private var cameraPreviewSession: CameraSessionReference?

    convenience init() {
        self.init(
            coordinator: RecordingCoordinator(),
            permissionCenter: PermissionCenter(),
            preferencesStore: PreferencesStore(),
            initialSnapshot: StudioRecorderSnapshot()
        )
    }

    init(
        coordinator: RecordingCoordinator?,
        permissionCenter: PermissionCenter? = nil,
        preferencesStore: PreferencesStore? = nil,
        initialSnapshot: StudioRecorderSnapshot
    ) {
        self.coordinator = coordinator
        self.permissionCenter = permissionCenter
        self.preferencesStore = preferencesStore ?? PreferencesStore()
        self.snapshot = initialSnapshot
        observeCoordinator()
    }

    func launch() async {
        snapshot.launchPhase = .checking
        if let permissionCenter {
            snapshot.permissionSnapshot = await permissionCenter.refresh()
        }
        guard let coordinator else { return }
        coordinator.configureProjectDestination(preferencesStore.destination.url)
        coordinator.refreshMicrophones()
        coordinator.refreshCameras()
        snapshot.availableMicrophones = coordinator.availableMicrophones
        snapshot.availableCameras = coordinator.availableCameras

        guard snapshot.permissionSnapshot.screenRecording.isGranted else {
            await coordinator.refreshProjects()
            snapshot.projects = coordinator.projects
            snapshot.interruptedProjects = coordinator.interruptedProjects
            snapshot.availableDisplays = []
            snapshot.applyCaptureState(.failed("Screen Recording access is required."))
            snapshot.launchPhase = .needsCaptureRepair(snapshot.permissionSnapshot)
            return
        }

        await coordinator.refreshDisplays()
        synchronizeFromCoordinator()
    }

    func appBecameActive() async {
        if snapshot.captureState == .preparing ||
            snapshot.captureState == .recording ||
            snapshot.captureState == .stopping {
            if let permissionCenter {
                snapshot.permissionSnapshot = await permissionCenter.refresh()
            }
            return
        }
        await launch()
    }

    func refreshCaptureSources() async {
        await launch()
    }

    func requestPermission(_ permission: CapturePermission) async {
        await permissionCenter?.request(permission)
        await launch()
    }

    func openSystemSettings(for permission: CapturePermission) {
        permissionCenter?.openSystemSettings(for: permission)
    }

    func useCameraPreviewSessionForRecording(_ session: AVCaptureSession?) {
        cameraPreviewSession = session.map(CameraSessionReference.init(session:))
    }

    @discardableResult
    func send(_ intent: AppIntent) -> AppIntentResult {
        let result: AppIntentResult

        switch intent {
        case .newRecording:
            snapshot.route = .studio
            snapshot.selectedProjectID = nil
            createFreshStudioDraft()
            result = .routeChanged(.studio)

        case .selectRoute(let route):
            guard route != .recovery || !snapshot.interruptedProjects.isEmpty else {
                return .ignored
            }
            snapshot.route = route
            if route == .studio, snapshot.studioDraft == nil, snapshot.activeCaptureRequest == nil {
                createFreshStudioDraft()
            }
            result = .routeChanged(route)

        case .openProject(let projectID):
            guard snapshot.projects.contains(where: { $0.id == projectID }) else {
                return .ignored
            }
            snapshot.route = .projects
            snapshot.selectedProjectID = projectID
            result = .projectOpened(projectID)

        case .closeProject:
            guard snapshot.selectedProjectID != nil else { return .ignored }
            snapshot.route = .projects
            snapshot.selectedProjectID = nil
            result = .projectClosed

        case .focusProjectSearch:
            snapshot.route = .projects
            result = .projectSearchRequested

        case .setSelectedDisplayIDs(let displayIDs):
            guard snapshot.captureState == .ready, !snapshot.isCaptureCommandInFlight else {
                return .ignored
            }
            snapshot.selectedDisplayIDs = displayIDs.intersection(Set(snapshot.availableDisplays.map(\.id)))
            snapshot.studioDraft?.selectedDisplayIDs = snapshot.selectedDisplayIDs
            result = .displaySelectionChanged

        case .setCapturesMicrophone(let capturesMicrophone):
            guard snapshot.route == .studio,
                  snapshot.captureState == .ready,
                  !snapshot.isCaptureCommandInFlight else {
                return .ignored
            }
            snapshot.capturesMicrophone = capturesMicrophone
            snapshot.studioDraft?.capturesMicrophone = capturesMicrophone
            result = .microphoneCaptureChanged

        case .setCapturesCamera(let capturesCamera):
            guard canEditDraft else { return .ignored }
            snapshot.capturesCamera = capturesCamera
            snapshot.studioDraft?.capturesCamera = capturesCamera
            result = .draftChanged

        case .setDraftCameraDeviceID(let deviceID):
            guard canEditDraft,
                  deviceID == nil || snapshot.availableCameras.contains(where: { $0.id == deviceID }) else {
                return .ignored
            }
            snapshot.studioDraft?.cameraDeviceID = deviceID
            result = .draftChanged

        case .setDraftCapturesSystemAudio(let captures):
            guard canEditDraft else { return .ignored }
            snapshot.studioDraft?.capturesSystemAudio = captures
            result = .draftChanged

        case .setDraftMicrophoneDeviceID(let deviceID):
            guard canEditDraft,
                  deviceID == nil || snapshot.availableMicrophones.contains(where: { $0.id == deviceID }) else {
                return .ignored
            }
            snapshot.studioDraft?.microphoneDeviceID = deviceID
            snapshot.studioDraft?.microphoneFallback = nil
            result = .draftChanged

        case .setDraftIncludeCursor(let includesCursor):
            guard canEditDraft else { return .ignored }
            snapshot.studioDraft?.includeCursor = includesCursor
            result = .draftChanged

        case .setDraftExcludeStudioRecorder(let excluded):
            guard canEditDraft else { return .ignored }
            snapshot.studioDraft?.excludeStudioRecorder = excluded
            result = .draftChanged

        case .setDraftExcludeStudioRecorderAudio(let excluded):
            guard canEditDraft else { return .ignored }
            snapshot.studioDraft?.excludeStudioRecorderAudio = excluded
            result = .draftChanged

        case .setDraftPresentation(let presentation):
            guard canEditDraft else { return .ignored }
            snapshot.studioDraft?.presentation = presentation.validated()
            result = .draftChanged

        case .setDraftRetentionPolicy(let policy):
            guard canEditDraft else { return .ignored }
            snapshot.studioDraft?.retentionPolicy = policy
            result = .draftChanged

        case .recordWithoutMicrophone:
            guard snapshot.route == .studio,
                  snapshot.captureState == .ready,
                  !snapshot.isCaptureCommandInFlight,
                  snapshot.capturesMicrophone else {
                return .ignored
            }
            snapshot.capturesMicrophone = false
            snapshot.studioDraft?.capturesMicrophone = false
            result = .microphoneDisabledForDraft

        case .recordWithoutCamera:
            guard canEditDraft, snapshot.capturesCamera else { return .ignored }
            snapshot.capturesCamera = false
            snapshot.studioDraft?.capturesCamera = false
            result = .cameraDisabledForDraft

        case .changePreference(let change):
            let isAppearanceChange: Bool = if case .appearance = change { true } else { false }
            guard isAppearanceChange || !snapshot.areRecordingSettingsLocked else { return .ignored }
            preferencesStore.update { preferences in
                switch change {
                case .appearance(let appearance): preferences.appearance = appearance
                case .codecPolicy(let policy): preferences.capture.codecPolicy = policy
                case .includeCursor(let includeCursor): preferences.capture.includeCursor = includeCursor
                case .excludeStudioRecorder(let excluded): preferences.capture.excludeStudioRecorder = excluded
                case .capturesSystemAudio(let captures): preferences.audio.capturesSystemAudio = captures
                case .capturesMicrophone(let captures): preferences.audio.capturesMicrophone = captures
                case .microphoneDeviceID(let id): preferences.audio.microphoneDeviceID = id
                case .excludeStudioRecorderAudio(let excluded): preferences.audio.excludeStudioRecorderAudio = excluded
                }
            }
            result = .preferenceChanged

        case .setProjectDestination(let url):
            guard !snapshot.areRecordingSettingsLocked else { return .ignored }
            do {
                try preferencesStore.setDestination(url)
                coordinator?.configureProjectDestination(preferencesStore.destination.url)
                result = .preferenceChanged
            } catch {
                result = .preferenceChangeFailed(error.localizedDescription)
            }

        case .toggleRecording:
            guard !snapshot.isCaptureCommandInFlight else {
                return .ignored
            }
            switch snapshot.captureState {
            case .ready:
                guard snapshot.route == .studio else { return .ignored }
                guard snapshot.requiredCapturePermission == nil else { return .ignored }
                guard !snapshot.selectedDisplayIDs.isEmpty else { return .ignored }
                var draft = snapshot.studioDraft ?? preferencesStore.makeStudioDraft(
                    displays: snapshot.availableDisplays,
                    microphones: snapshot.availableMicrophones,
                    cameras: snapshot.availableCameras
                )
                draft.selectedDisplayIDs = snapshot.selectedDisplayIDs
                draft.capturesMicrophone = snapshot.capturesMicrophone
                draft.capturesCamera = snapshot.capturesCamera
                guard let request = try? draft.freeze(
                    displays: snapshot.availableDisplays,
                    microphones: snapshot.availableMicrophones,
                    cameras: snapshot.availableCameras,
                    permissions: snapshot.permissionSnapshot
                ) else {
                    return .ignored
                }
                snapshot.studioDraft = draft
                snapshot.activeCaptureRequest = request
                snapshot.beginCaptureCommand(.start)
                result = .recordingStartRequested(request)

            case .recording:
                snapshot.beginCaptureCommand(.stop)
                result = .recordingStopRequested

            case .preparing, .stopping, .failed:
                return .ignored
            }
        }

        execute(result)
        return result
    }

    private var canEditDraft: Bool {
        snapshot.route == .studio &&
            snapshot.captureState == .ready &&
            !snapshot.isCaptureCommandInFlight &&
            snapshot.studioDraft != nil
    }

    private func createFreshStudioDraft() {
        let draft = preferencesStore.makeStudioDraft(
            displays: snapshot.availableDisplays,
            microphones: snapshot.availableMicrophones,
            cameras: snapshot.availableCameras
        )
        snapshot.studioDraft = draft
        snapshot.selectedDisplayIDs = draft.selectedDisplayIDs
        snapshot.capturesMicrophone = draft.capturesMicrophone
        snapshot.capturesCamera = draft.capturesCamera
    }

    private func observeCoordinator() {
        guard let coordinator else { return }
        coordinatorObservation = coordinator.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.synchronizeFromCoordinator()
            }
        }
    }

    private func execute(_ result: AppIntentResult) {
        guard let coordinator else { return }

        switch result {
        case .recordingStartRequested(let request):
            let cameraPreviewSession = cameraPreviewSession
            Task { @MainActor [weak self] in
                await coordinator.startRecording(request, cameraPreviewSession: cameraPreviewSession)
                self?.cameraPreviewSession = nil
                self?.synchronizeFromCoordinator()
            }

        case .recordingStopRequested:
            Task { @MainActor [weak self] in
                await coordinator.stopRecording()
                self?.synchronizeFromCoordinator()
            }

        case .ignored, .routeChanged, .projectOpened, .projectClosed, .projectSearchRequested, .displaySelectionChanged,
             .microphoneCaptureChanged, .microphoneDisabledForDraft, .cameraDisabledForDraft, .draftChanged:
            break
        case .preferenceChanged, .preferenceChangeFailed:
            break
        }
    }

    private func synchronizeFromCoordinator() {
        guard let coordinator else { return }

        snapshot.applyCaptureState(coordinator.state)
        snapshot.availableDisplays = coordinator.availableDisplays
        snapshot.availableMicrophones = coordinator.availableMicrophones
        snapshot.availableCameras = coordinator.availableCameras
        snapshot.projects = coordinator.projects
        snapshot.interruptedProjects = coordinator.interruptedProjects
        snapshot.finalizationWarning = coordinator.finalizationWarning

        if snapshot.studioDraft != nil {
            snapshot.studioDraft?.reconcile(
                displays: coordinator.availableDisplays,
                microphones: coordinator.availableMicrophones,
                cameras: coordinator.availableCameras
            )
            snapshot.selectedDisplayIDs = snapshot.studioDraft?.selectedDisplayIDs ?? []
            snapshot.capturesMicrophone = snapshot.studioDraft?.capturesMicrophone ?? false
            snapshot.capturesCamera = snapshot.studioDraft?.capturesCamera ?? false
        } else {
            let availableDisplayIDs = Set(coordinator.availableDisplays.map(\.id))
            snapshot.selectedDisplayIDs.formIntersection(availableDisplayIDs)
            if snapshot.selectedDisplayIDs.isEmpty, let firstDisplayID = coordinator.availableDisplays.first?.id {
                snapshot.selectedDisplayIDs = [firstDisplayID]
            }
        }
        if coordinator.activeCaptureRequest == nil {
            snapshot.activeCaptureRequest = nil
        }

        if snapshot.requiredCapturePermission != nil {
            snapshot.launchPhase = .needsCaptureRepair(snapshot.permissionSnapshot)
        } else {
            switch coordinator.state {
            case .failed:
                snapshot.launchPhase = .needsCaptureRepair(snapshot.permissionSnapshot)
            case .preparing:
                snapshot.launchPhase = .checking
            case .ready, .recording, .stopping:
                snapshot.launchPhase = .ready
            }
        }

        if snapshot.route == .recovery, snapshot.interruptedProjects.isEmpty {
            snapshot.route = .projects
        }
    }
}
