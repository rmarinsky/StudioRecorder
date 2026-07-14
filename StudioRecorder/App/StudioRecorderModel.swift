import Combine
import Foundation

enum MainRoute: Hashable {
    case projects
    case studio
    case recovery
}

enum LaunchPhase: Equatable {
    case checking
    case ready
    case captureUnavailable(String)
}

enum AppIntent: Equatable {
    case newRecording
    case selectRoute(MainRoute)
    case openProject(String)
    case focusProjectSearch
    case toggleRecording
    case setSelectedDisplayIDs(Set<UInt32>)
}

enum AppIntentResult: Equatable {
    case ignored
    case routeChanged(MainRoute)
    case projectOpened(String)
    case projectSearchRequested
    case recordingStartRequested(Set<UInt32>)
    case recordingStopRequested
    case displaySelectionChanged
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
    private(set) var pendingCaptureCommand: PendingCaptureCommand?

    var isCaptureCommandInFlight: Bool { pendingCaptureCommand != nil }

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

@MainActor
final class StudioRecorderModel: ObservableObject {
    @Published private(set) var snapshot: StudioRecorderSnapshot

    private let coordinator: RecordingCoordinator?
    private var coordinatorObservation: AnyCancellable?

    convenience init() {
        self.init(coordinator: RecordingCoordinator(), initialSnapshot: StudioRecorderSnapshot())
    }

    init(coordinator: RecordingCoordinator?, initialSnapshot: StudioRecorderSnapshot) {
        self.coordinator = coordinator
        self.snapshot = initialSnapshot
        observeCoordinator()
    }

    func launch() async {
        snapshot.launchPhase = .checking
        guard let coordinator else { return }
        await coordinator.refreshDisplays()
        synchronizeFromCoordinator()
    }

    func refreshCaptureSources() async {
        await launch()
    }

    func openScreenRecordingSettings() {
        coordinator?.openScreenRecordingSettings()
    }

    @discardableResult
    func send(_ intent: AppIntent) -> AppIntentResult {
        let result: AppIntentResult

        switch intent {
        case .newRecording:
            snapshot.route = .studio
            snapshot.selectedProjectID = nil
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

        case .toggleRecording:
            guard !snapshot.isCaptureCommandInFlight else {
                return .ignored
            }
            switch snapshot.captureState {
            case .ready:
                guard snapshot.route == .studio else { return .ignored }
                guard !snapshot.selectedDisplayIDs.isEmpty else { return .ignored }
                snapshot.beginCaptureCommand(.start)
                result = .recordingStartRequested(snapshot.selectedDisplayIDs)

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
        case .recordingStartRequested(let displayIDs):
            Task { @MainActor [weak self] in
                await coordinator.startRecording(selectedDisplayIDs: displayIDs)
                self?.synchronizeFromCoordinator()
            }

        case .recordingStopRequested:
            Task { @MainActor [weak self] in
                await coordinator.stopRecording()
                self?.synchronizeFromCoordinator()
            }

        case .ignored, .routeChanged, .projectOpened, .projectSearchRequested, .displaySelectionChanged:
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

        switch coordinator.state {
        case .failed(let message):
            snapshot.launchPhase = .captureUnavailable(message)
        case .preparing:
            snapshot.launchPhase = .checking
        case .ready, .recording, .stopping:
            snapshot.launchPhase = .ready
        }

        if snapshot.route == .recovery, snapshot.interruptedProjects.isEmpty {
            snapshot.route = .projects
        }
    }
}
