import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

@MainActor
final class SafeShortcutMonitor: ObservableObject {
    @Published private(set) var visibleLabel: String?
    @Published private(set) var hasGlobalAccess = CGPreflightListenEventAccess()

    var onShortcut: ((String) -> Void)?

    private var isEnabled = false
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var hideTask: Task<Void, Never>?

    func update(isEnabled: Bool) {
        guard self.isEnabled != isEnabled else { return }
        self.isEnabled = isEnabled
        isEnabled ? installMonitors() : stop()
    }

    func refreshAccess() {
        let granted = CGPreflightListenEventAccess()
        guard hasGlobalAccess != granted else { return }
        hasGlobalAccess = granted
        if isEnabled {
            removeGlobalMonitor()
            installGlobalMonitorIfAllowed()
        }
    }

    func requestGlobalAccess() {
        hasGlobalAccess = CGRequestListenEventAccess()
        if isEnabled {
            removeGlobalMonitor()
            installGlobalMonitorIfAllowed()
        }
    }

    func clearVisibleShortcut() {
        hideTask?.cancel()
        hideTask = nil
        visibleLabel = nil
    }

    func stop() {
        isEnabled = false
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        removeGlobalMonitor()
        clearVisibleShortcut()
    }

    private func installMonitors() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let input = Self.makeInput(from: event)
            Task { @MainActor [weak self] in self?.accept(input) }
            return event
        }
        installGlobalMonitorIfAllowed()
    }

    private func installGlobalMonitorIfAllowed() {
        guard hasGlobalAccess, globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let input = Self.makeInput(from: event)
            Task { @MainActor [weak self] in self?.accept(input) }
        }
    }

    private func removeGlobalMonitor() {
        guard let globalMonitor else { return }
        NSEvent.removeMonitor(globalMonitor)
        self.globalMonitor = nil
    }

    private func accept(_ input: SafeShortcutInput) {
        guard isEnabled,
              let label = SafeShortcutClassifier.label(for: input) else { return }
        visibleLabel = label
        onShortcut?(label)
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.visibleLabel = nil
        }
    }

    nonisolated private static func makeInput(from event: NSEvent) -> SafeShortcutInput {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: SafeShortcutModifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return SafeShortcutInput(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: modifiers,
            isRepeat: event.isARepeat,
            isSecureInputEnabled: IsSecureEventInputEnabled()
        )
    }
}
