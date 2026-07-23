import SwiftUI

@main
struct StudioRecorderApp: App {
    @StateObject private var preferencesStore: PreferencesStore
    @StateObject private var streamingSettings: YouTubeStreamingSettingsStore
    @StateObject private var managedYouTube: YouTubeManagedSessionCoordinator
    @StateObject private var model: StudioRecorderModel
    @StateObject private var sceneLibrary: StudioSceneLibraryStore

    init() {
        let preferencesStore = PreferencesStore()
        _preferencesStore = StateObject(wrappedValue: preferencesStore)
        _streamingSettings = StateObject(wrappedValue: YouTubeStreamingSettingsStore())
        _managedYouTube = StateObject(wrappedValue: YouTubeManagedSessionCoordinator())
        _sceneLibrary = StateObject(wrappedValue: StudioSceneLibraryStore())
        _model = StateObject(
            wrappedValue: StudioRecorderModel(
                coordinator: RecordingCoordinator(),
                permissionCenter: PermissionCenter(),
                preferencesStore: preferencesStore,
                initialSnapshot: StudioRecorderSnapshot()
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            StudioRecorderRootView(
                model: model,
                preferencesStore: preferencesStore,
                streamingSettings: streamingSettings,
                managedYouTube: managedYouTube,
                sceneLibrary: sceneLibrary
            )
                .frame(minWidth: 1_080, minHeight: 700)
                .preferredColorScheme(preferencesStore.preferences.appearance.colorScheme)
        }
        .defaultSize(width: 1_260, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                OpenSettingsCommand()
            }
            CommandGroup(after: .newItem) {
                OpenRecordingControlsCommand()

                Button("New Recording") {
                    NotificationCenter.default.post(name: .studioRecorderNewRecording, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Start or stop recording") {
                    model.send(.toggleRecording)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button(model.snapshot.captureState == .paused ? "Resume Recording" : "Pause Recording") {
                    model.send(.toggleRecordingPause)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(
                    model.snapshot.captureState != .recording
                        && model.snapshot.captureState != .paused
                )

                Button("Find Projects") {
                    NotificationCenter.default.post(name: .studioRecorderFindProjects, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }

        Window("Recording Controls", id: "recording-controls") {
            RecordingControlsView(model: model, sceneLibrary: sceneLibrary)
                .preferredColorScheme(preferencesStore.preferences.appearance.colorScheme)
        }
        .defaultSize(width: 360, height: 280)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Window("Settings", id: "settings") {
            SettingsView(
                model: model,
                preferencesStore: preferencesStore,
                streamingSettings: streamingSettings,
                managedYouTube: managedYouTube
            )
            .preferredColorScheme(preferencesStore.preferences.appearance.colorScheme)
        }
        .defaultSize(width: 760, height: 540)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

    }
}

extension Notification.Name {
    static let studioRecorderNewRecording = Notification.Name("StudioRecorder.newRecording")
    static let studioRecorderFindProjects = Notification.Name("StudioRecorder.findProjects")
}

private struct OpenSettingsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") { openWindow(id: "settings") }
            .keyboardShortcut(",", modifiers: .command)
    }
}

private struct OpenRecordingControlsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Recording Controls") { openWindow(id: "recording-controls") }
            .keyboardShortcut("c", modifiers: [.command, .shift])
    }
}

enum RecordingControlPanelPolicy {
    static func canSwitchScenes(_ snapshot: StudioRecorderSnapshot) -> Bool {
        (snapshot.captureState == .recording || snapshot.captureState == .paused)
            && snapshot.activeCaptureRequest != nil
            && !snapshot.isCaptureCommandInFlight
    }

    static func liveContract(_ snapshot: StudioRecorderSnapshot) -> StudioSceneLiveContract? {
        guard canSwitchScenes(snapshot), let request = snapshot.activeCaptureRequest else { return nil }
        return StudioSceneLiveContract(
            initialPresentation: request.presentation,
            capturesCamera: request.camera != nil,
            recordsCursorTelemetry: request.includesCursor
                || request.presentation.framing.mode == .followCursor
        )
    }
}

private struct RecordingControlsView: View {
    @ObservedObject var model: StudioRecorderModel
    @ObservedObject var sceneLibrary: StudioSceneLibraryStore
    @AppStorage("controlPanelShowsTransport") private var showsTransport = true
    @AppStorage("controlPanelShowsScenes") private var showsScenes = true
    @State private var isCompact = false

    private var snapshot: StudioRecorderSnapshot { model.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 7) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(snapshot.captureState.label.uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(statusColor)
                }
                Text(formattedDuration)
                    .font(.body.monospacedDigit().weight(.medium))
                Spacer()
                Label("Excluded", systemImage: "eye.slash")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .help("This window is excluded from screen capture.")
                Button {
                    isCompact.toggle()
                } label: {
                    Image(systemName: isCompact ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                }
                .buttonStyle(.plain)
                .help(isCompact ? "Show scene controls" : "Compact controls")
            }

            if snapshot.captureState == .recording || snapshot.captureState == .paused {
                Label(sourceStatusText, systemImage: sourceStatusIcon)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(sourceStatusColor)
                    .lineLimit(2)
            }

            if showsTransport { transportControls }
            sourceControls
            if showsScenes && !isCompact { sceneControls }
        }
        .padding(14)
        .frame(width: 370)
        .background(
            Color(red: 0.075, green: 0.078, blue: 0.084),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .tint(Color(red: 0.90, green: 0.40, blue: 0.36))
        .background(ControlWindowConfigurator())
    }

    private var transportControls: some View {
        HStack(spacing: 8) {
            Button {
                model.send(.toggleRecording)
            } label: {
                Label(
                    snapshot.captureState == .recording || snapshot.captureState == .paused ? "Stop" : "Record",
                    systemImage: snapshot.captureState == .recording || snapshot.captureState == .paused
                        ? "stop.fill" : "record.circle"
                )
            }
            .keyboardShortcut("r", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .tint(snapshot.captureState == .recording || snapshot.captureState == .paused ? .red : .accentColor)
            .disabled(!canToggleRecording)

            Button {
                model.send(.toggleRecordingPause)
            } label: {
                Label(snapshot.captureState == .paused ? "Resume" : "Pause", systemImage: snapshot.captureState == .paused ? "play.fill" : "pause.fill")
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(snapshot.captureState != .recording && snapshot.captureState != .paused)

            Spacer()

            Button {
                switchToNextScene()
            } label: {
                Label("Next", systemImage: "arrow.right")
            }
            .disabled(!canSwitchToNextScene)
            .help("Switch to the next compatible scene")
        }
    }

    private var sourceControls: some View {
        HStack(spacing: 8) {
            sourceButton(
                title: snapshot.capturesMicrophone ? "Mic On" : "Mic Off",
                icon: snapshot.capturesMicrophone ? "mic.fill" : "mic.slash.fill",
                isActive: snapshot.capturesMicrophone,
                isEnabled: snapshot.captureState == .ready
            ) {
                model.send(.setCapturesMicrophone(!snapshot.capturesMicrophone))
            }
            .help(snapshot.captureState == .ready ? "Include or exclude the microphone from this session" : "Microphone capture is fixed after recording starts")

            sourceButton(
                title: cameraControlTitle,
                icon: cameraIsVisible ? "video.fill" : "video.slash.fill",
                isActive: cameraIsVisible,
                isEnabled: snapshot.capturesCamera
            ) {
                toggleCameraVisibility()
            }
            .help(snapshot.capturesCamera ? "Show or hide the camera in the program" : "Camera is not enabled for this session")

            sourceButton(
                title: snapshot.studioDraft?.capturesSystemAudio == true ? "Audio On" : "Audio Off",
                icon: snapshot.studioDraft?.capturesSystemAudio == true ? "speaker.wave.2.fill" : "speaker.slash.fill",
                isActive: snapshot.studioDraft?.capturesSystemAudio == true,
                isEnabled: snapshot.captureState == .ready
            ) {
                model.send(.setDraftCapturesSystemAudio(snapshot.studioDraft?.capturesSystemAudio != true))
            }
            .help(snapshot.captureState == .ready ? "Include or exclude system audio from this session" : "System audio capture is fixed after recording starts")
        }
    }

    private func sourceButton(
        title: String,
        icon: String,
        isActive: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.medium))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(isActive ? .accentColor : .secondary)
        .disabled(!isEnabled)
    }

    @ViewBuilder
    private var sceneControls: some View {
        Divider()
        HStack {
            Text("SCENES")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("⌥1–9")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        if sceneLibrary.scenes.isEmpty {
            Text("Save scenes in Recording Studio to use them here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            let contract = RecordingControlPanelPolicy.liveContract(snapshot)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(sceneLibrary.scenes.enumerated()), id: \.element.id) { index, scene in
                        let issue = contract?.incompatibility(for: scene.presentation)
                        Button {
                            model.send(.switchScenePreset(scene))
                        } label: {
                            HStack {
                                Image(systemName: activeSceneID == scene.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(activeSceneID == scene.id ? Color.accentColor : Color.secondary)
                                Text(scene.name).lineLimit(1)
                                Spacer()
                                Text(scene.incomingTransition.effect.label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if index < 9 {
                                    Text("⌥\(index + 1)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                if issue != nil { Image(systemName: "lock.fill").font(.caption) }
                            }
                            .frame(minHeight: 28)
                        }
                        .buttonStyle(.plain)
                        .disabled(!RecordingControlPanelPolicy.canSwitchScenes(snapshot) || issue != nil)
                        .help(issue?.message ?? sceneHelp)
                        .applySceneShortcut(index: index)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
    }

    private var activeSceneID: UUID? {
        guard let draft = snapshot.studioDraft else { return nil }
        let sources = StudioSceneSourceState(draft: draft)
        return sceneLibrary.scenes.first {
            $0.presentation.validated() == draft.presentation.validated()
                && ($0.sources == nil || $0.sources == sources)
        }?.id
    }

    private var sceneHelp: String {
        RecordingControlPanelPolicy.canSwitchScenes(snapshot)
            ? "Switch scene"
            : "Start a local recording to switch scenes here."
    }

    private var cameraIsVisible: Bool {
        snapshot.capturesCamera && snapshot.studioDraft?.presentation.camera.isVisible == true
    }

    private var cameraControlTitle: String {
        guard snapshot.capturesCamera else { return "No Camera" }
        return cameraIsVisible ? "Camera On" : "Camera Off"
    }

    private func toggleCameraVisibility() {
        guard var presentation = snapshot.studioDraft?.presentation, snapshot.capturesCamera else { return }
        presentation.camera.isVisible.toggle()
        model.send(.setDraftPresentation(presentation))
    }

    private var canSwitchToNextScene: Bool {
        RecordingControlPanelPolicy.canSwitchScenes(snapshot) && sceneLibrary.scenes.count > 1
    }

    private func switchToNextScene() {
        guard canSwitchToNextScene else { return }
        let currentIndex = sceneLibrary.scenes.firstIndex { $0.id == activeSceneID } ?? -1
        let nextIndex = (currentIndex + 1) % sceneLibrary.scenes.count
        model.send(.switchScenePreset(sceneLibrary.scenes[nextIndex]))
    }

    private var formattedDuration: String {
        let total = max(Int(snapshot.recordedDuration), 0)
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    private var sourceStatusText: String {
        switch snapshot.sourceRecoveryState {
        case .restarting(let source, let attempt, let maximumAttempts):
            "Healing \(source.label) · attempt \(attempt)/\(maximumAttempts)"
        case .waitingForSamples(let source, _, _):
            "\(source.label) refreshed · verifying frames"
        case .failed(let source, _):
            "\(source.label) unavailable · recording continues with cached content"
        case .idle:
            if let source = snapshot.sourceHealth.stalledSources.first {
                "\(source.label) stalled · holding the last good frame"
            } else {
                "All recording sources are receiving"
            }
        }
    }

    private var sourceStatusIcon: String {
        snapshot.sourceHealth.hasStalledSources ? "arrow.trianglehead.2.clockwise.rotate.90" : "checkmark.circle.fill"
    }

    private var sourceStatusColor: Color {
        snapshot.sourceHealth.hasStalledSources ? .orange : .green
    }

    private var canToggleRecording: Bool {
        !snapshot.isCaptureCommandInFlight
            && (snapshot.captureState == .ready
                || snapshot.captureState == .recording
                || snapshot.captureState == .paused)
    }

    private var statusIcon: String {
        switch snapshot.captureState {
        case .recording: "record.circle.fill"
        case .paused: "pause.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .preparing, .ready, .stopping: "circle.fill"
        }
    }

    private var statusColor: Color {
        switch snapshot.captureState {
        case .recording: .red
        case .paused, .failed: .orange
        case .ready: .green
        case .preparing, .stopping: .secondary
        }
    }
}

private extension View {
    @ViewBuilder
    func applySceneShortcut(index: Int) -> some View {
        if index < 9 {
            keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .option)
        } else {
            self
        }
    }
}

private struct ControlWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        window?.sharingType = .none
        window?.level = .floating
        window?.collectionBehavior.insert(.moveToActiveSpace)
        window?.isMovableByWindowBackground = true
        window?.titleVisibility = .hidden
        window?.titlebarAppearsTransparent = true
    }
}
