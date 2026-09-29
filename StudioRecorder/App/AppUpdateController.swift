import AppKit
import Combine
import Foundation
import Sparkle

struct AppUpdateConfiguration {
    let unavailableReason: String?
    var isEnabled: Bool { unavailableReason == nil }

    init(info: [String: Any], bundleIdentifier: String?) {
        let enabled = (info["StudioRecorderUpdatesEnabled"] as? String) == "YES"
            || (info["StudioRecorderUpdatesEnabled"] as? Bool) == true
        guard enabled, bundleIdentifier == "ua.com.rmarinsky.studiorecorder" else {
            unavailableReason = "Updates are available in the release app. Development builds are updated locally."
            return
        }
        guard let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil,
              let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32 else {
            unavailableReason = "Update signing is not configured for this build."
            return
        }
        unavailableReason = nil
    }
}

@MainActor
final class UpdateInstallationGate {
    private var installHandler: (() -> Void)?

    func postponeIfBusy(_ busy: Bool, install: @escaping () -> Void) -> Bool {
        guard busy else { return false }
        installHandler = install
        return true
    }

    func resumeIfIdle(_ busy: Bool) {
        guard !busy, let handler = installHandler else { return }
        installHandler = nil
        handler()
    }

    func cancel() { installHandler = nil }
}

@MainActor
final class AppUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var isWaitingForIdle = false
    let unavailableReason: String?
    private let model: StudioRecorderModel
    private let gate = UpdateInstallationGate()
    private var controller: SPUStandardUpdaterController?
    private var activities: [UUID: () -> Bool] = [:]
    private var waitTask: Task<Void, Never>?
    private var isInstallingUpdate = false
    private var terminationReply: ((Bool) -> Void)?

    init(model: StudioRecorderModel, bundle: Bundle = .main) {
        self.model = model
        let configuration = AppUpdateConfiguration(
            info: bundle.infoDictionary ?? [:], bundleIdentifier: bundle.bundleIdentifier
        )
        unavailableReason = configuration.unavailableReason
        super.init()
        guard configuration.isEnabled else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
        )
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard canCheckForUpdates, !isWaitingForIdle else { return }
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func registerActivity(_ id: UUID, isBusy: @escaping () -> Bool) { activities[id] = isBusy }
    func unregisterActivity(_ id: UUID) { activities[id] = nil }

    private var isBusy: Bool {
        model.snapshot.areRecordingSettingsLocked || model.snapshot.isCaptureCommandInFlight
            || model.snapshot.jobs.contains { $0.state == .queued || $0.state == .running }
            || activities.values.contains { $0() }
    }

    func updater(
        _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        postponeUntilIdle(installHandler)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        isInstallingUpdate = true
    }

    // Sparkle can skip its relaunch postponement hook on a resumed installation.
    func postponeTerminationIfNeeded(_ reply: @escaping (Bool) -> Void) -> Bool {
        guard isInstallingUpdate, isBusy else { return false }
        terminationReply = reply
        return postponeUntilIdle { [weak self] in
            self?.terminationReply = nil
            reply(true)
        }
    }

    private func postponeUntilIdle(_ installHandler: @escaping () -> Void) -> Bool {
        guard gate.postponeIfBusy(isBusy, install: installHandler) else { return false }
        isWaitingForIdle = true
        waitTask?.cancel()
        waitTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                if !isBusy {
                    isWaitingForIdle = false
                    waitTask = nil
                    gate.resumeIfIdle(false)
                    return
                }
            }
        }
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        waitTask?.cancel()
        waitTask = nil
        gate.cancel()
        isWaitingForIdle = false
        isInstallingUpdate = false
        let reply = terminationReply
        terminationReply = nil
        reply?(false)
    }
}

@MainActor
final class UpdateApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var updates: AppUpdateController?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if updates?.postponeTerminationIfNeeded({ sender.reply(toApplicationShouldTerminate: $0) }) == true {
            return .terminateLater
        }
        return .terminateNow
    }
}
