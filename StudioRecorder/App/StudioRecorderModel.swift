import AppKit
import AVFoundation
import Combine
import CoreGraphics
import Foundation

enum CapturePermission: Equatable {
    case screenRecording
    case microphone
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

    static let checking = PermissionSnapshot(screenRecording: .checking, microphone: .checking)

    func requiredPermission(capturesMicrophone: Bool) -> CapturePermission? {
        if !screenRecording.isGranted { return .screenRecording }
        if capturesMicrophone, !microphone.isGranted { return .microphone }
        return nil
    }
}

@MainActor
final class PermissionCenter {
    typealias ScreenPreflight = () -> Bool
    typealias ScreenRequest = () -> Bool
    typealias MicrophoneStatus = () -> AVAuthorizationStatus
    typealias MicrophoneRequest = () async -> Bool
    typealias OpenURL = (URL) -> Void

    private let screenPreflight: ScreenPreflight
    private let screenRequest: ScreenRequest
    private let microphoneStatus: MicrophoneStatus
    private let microphoneRequest: MicrophoneRequest
    private let openURL: OpenURL
    private var screenGrantAcceptedInCurrentProcess = false

    convenience init() {
        self.init(
            screenPreflight: { CGPreflightScreenCaptureAccess() },
            screenRequest: { CGRequestScreenCaptureAccess() },
            microphoneStatus: { AVCaptureDevice.authorizationStatus(for: .audio) },
            microphoneRequest: { await AVCaptureDevice.requestAccess(for: .audio) },
            openURL: { NSWorkspace.shared.open($0) }
        )
    }

    init(
        screenPreflight: @escaping ScreenPreflight,
        screenRequest: @escaping ScreenRequest,
        microphoneStatus: @escaping MicrophoneStatus,
        microphoneRequest: @escaping MicrophoneRequest,
        openURL: @escaping OpenURL
    ) {
        self.screenPreflight = screenPreflight
        self.screenRequest = screenRequest
        self.microphoneStatus = microphoneStatus
        self.microphoneRequest = microphoneRequest
        self.openURL = openURL
    }

    func refresh() async -> PermissionSnapshot {
        PermissionSnapshot(
            screenRecording: screenAccessState(),
            microphone: microphoneAccessState()
        )
    }

    func request(_ permission: CapturePermission) async {
        switch permission {
        case .screenRecording:
            screenGrantAcceptedInCurrentProcess = screenRequest()
        case .microphone:
            guard microphoneAccessState() == .notDetermined else { return }
            _ = await microphoneRequest()
        }
    }

    func openSystemSettings(for permission: CapturePermission) {
        let pane: String
        switch permission {
        case .screenRecording:
            pane = "Privacy_ScreenCapture"
        case .microphone:
            pane = "Privacy_Microphone"
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
        switch microphoneStatus() {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .granted
        case .restricted: return .unavailable("Microphone access is restricted.")
        @unknown default: return .unavailable("Microphone permission status is unavailable.")
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
    case focusProjectSearch
    case toggleRecording
    case setSelectedDisplayIDs(Set<UInt32>)
    case setCapturesMicrophone(Bool)
    case recordWithoutMicrophone
}

enum AppIntentResult: Equatable {
    case ignored
    case routeChanged(MainRoute)
    case projectOpened(String)
    case projectSearchRequested
    case recordingStartRequested(displayIDs: Set<UInt32>, capturesMicrophone: Bool)
    case recordingStopRequested
    case displaySelectionChanged
    case microphoneCaptureChanged
    case microphoneDisabledForDraft
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
    var projects: [RecordingProjectSnapshot] = []
    var interruptedProjects: [RecordingProjectSnapshot] = []
    var selectedDisplayIDs: Set<UInt32> = []
    var permissionSnapshot: PermissionSnapshot = .checking
    var capturesMicrophone = true
    private(set) var pendingCaptureCommand: PendingCaptureCommand?

    var isCaptureCommandInFlight: Bool { pendingCaptureCommand != nil }
    var requiredCapturePermission: CapturePermission? {
        permissionSnapshot.requiredPermission(capturesMicrophone: capturesMicrophone)
    }
    var showsCaptureRepair: Bool {
        guard requiredCapturePermission != nil else { return false }
        return captureState != .recording && captureState != .stopping
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
    let showsLoadingSkeleton: Bool
    let actions: [PermissionRepairAction]
}

extension StudioRecorderSnapshot {
    var permissionRepairPresentation: PermissionRepairPresentation? {
        guard showsCaptureRepair, let permission = requiredCapturePermission else { return nil }
        let state: PermissionAccessState = switch permission {
        case .screenRecording: permissionSnapshot.screenRecording
        case .microphone: permissionSnapshot.microphone
        }
        let title: String = switch (permission, state) {
        case (.screenRecording, .grantedButRelaunchRequired): "Relaunch Studio Recorder"
        case (.screenRecording, _): "Allow Screen Recording"
        case (.microphone, .notDetermined): "Allow Microphone"
        case (.microphone, _): "Microphone access needs attention"
        }
        let explanation: String = switch permission {
        case .screenRecording:
            "Screen Recording is required to discover and record selected displays. Existing projects remain available."
        case .microphone:
            "The current Studio Draft includes microphone capture. Repair access or record this draft without a microphone."
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
    private var coordinatorObservation: AnyCancellable?

    convenience init() {
        self.init(
            coordinator: RecordingCoordinator(),
            permissionCenter: PermissionCenter(),
            initialSnapshot: StudioRecorderSnapshot()
        )
    }

    init(
        coordinator: RecordingCoordinator?,
        permissionCenter: PermissionCenter? = nil,
        initialSnapshot: StudioRecorderSnapshot
    ) {
        self.coordinator = coordinator
        self.permissionCenter = permissionCenter
        self.snapshot = initialSnapshot
        observeCoordinator()
    }

    func launch() async {
        snapshot.launchPhase = .checking
        if let permissionCenter {
            snapshot.permissionSnapshot = await permissionCenter.refresh()
        }
        guard let coordinator else { return }

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

    @discardableResult
    func send(_ intent: AppIntent) -> AppIntentResult {
        let result: AppIntentResult

        switch intent {
        case .newRecording:
            snapshot.route = .studio
            snapshot.selectedProjectID = nil
            snapshot.capturesMicrophone = true
            result = .routeChanged(.studio)

        case .selectRoute(let route):
            guard route != .recovery || !snapshot.interruptedProjects.isEmpty else {
                return .ignored
            }
            snapshot.route = route
            result = .routeChanged(route)

        case .openProject(let projectID):
            guard snapshot.projects.contains(where: { $0.id == projectID }) else {
                return .ignored
            }
            snapshot.route = .projects
            snapshot.selectedProjectID = projectID
            result = .projectOpened(projectID)

        case .focusProjectSearch:
            snapshot.route = .projects
            result = .projectSearchRequested

        case .setSelectedDisplayIDs(let displayIDs):
            guard snapshot.captureState == .ready, !snapshot.isCaptureCommandInFlight else {
                return .ignored
            }
            snapshot.selectedDisplayIDs = displayIDs.intersection(Set(snapshot.availableDisplays.map(\.id)))
            result = .displaySelectionChanged

        case .setCapturesMicrophone(let capturesMicrophone):
            guard snapshot.route == .studio,
                  snapshot.captureState == .ready,
                  !snapshot.isCaptureCommandInFlight else {
                return .ignored
            }
            snapshot.capturesMicrophone = capturesMicrophone
            result = .microphoneCaptureChanged

        case .recordWithoutMicrophone:
            guard snapshot.route == .studio,
                  snapshot.captureState == .ready,
                  !snapshot.isCaptureCommandInFlight,
                  snapshot.capturesMicrophone else {
                return .ignored
            }
            snapshot.capturesMicrophone = false
            result = .microphoneDisabledForDraft

        case .toggleRecording:
            guard !snapshot.isCaptureCommandInFlight else {
                return .ignored
            }
            switch snapshot.captureState {
            case .ready:
                guard snapshot.route == .studio else { return .ignored }
                guard snapshot.requiredCapturePermission == nil else { return .ignored }
                guard !snapshot.selectedDisplayIDs.isEmpty else { return .ignored }
                snapshot.beginCaptureCommand(.start)
                result = .recordingStartRequested(
                    displayIDs: snapshot.selectedDisplayIDs,
                    capturesMicrophone: snapshot.capturesMicrophone
                )

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
        case .recordingStartRequested(let displayIDs, let capturesMicrophone):
            Task { @MainActor [weak self] in
                await coordinator.startRecording(
                    selectedDisplayIDs: displayIDs,
                    capturesMicrophone: capturesMicrophone
                )
                self?.synchronizeFromCoordinator()
            }

        case .recordingStopRequested:
            Task { @MainActor [weak self] in
                await coordinator.stopRecording()
                self?.synchronizeFromCoordinator()
            }

        case .ignored, .routeChanged, .projectOpened, .projectSearchRequested, .displaySelectionChanged,
             .microphoneCaptureChanged, .microphoneDisabledForDraft:
            break
        }
    }

    private func synchronizeFromCoordinator() {
        guard let coordinator else { return }

        snapshot.applyCaptureState(coordinator.state)
        snapshot.availableDisplays = coordinator.availableDisplays
        snapshot.projects = coordinator.projects
        snapshot.interruptedProjects = coordinator.interruptedProjects

        let availableDisplayIDs = Set(coordinator.availableDisplays.map(\.id))
        snapshot.selectedDisplayIDs.formIntersection(availableDisplayIDs)
        if snapshot.selectedDisplayIDs.isEmpty, !availableDisplayIDs.isEmpty {
            snapshot.selectedDisplayIDs = availableDisplayIDs
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
