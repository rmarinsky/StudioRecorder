import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Hashable {
    case general
    case assistant
    case audio
    case streaming
    case storage
    case shortcuts

    var title: String { rawValue.capitalized }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .assistant: "sparkles"
        case .audio: "waveform"
        case .streaming: "dot.radiowaves.left.and.right"
        case .storage: "internaldrive"
        case .shortcuts: "keyboard"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: StudioRecorderModel
    @ObservedObject var preferencesStore: PreferencesStore
    @ObservedObject var streamingSettings: YouTubeStreamingSettingsStore
    @ObservedObject var managedYouTube: YouTubeManagedSessionCoordinator
    var embedded = false
    var selectedTab = SettingsTab.general
    @AppStorage("selectedSettingsTab") private var selectedSettingsTabRaw = SettingsTab.general.rawValue
    @AppStorage("controlPanelShowsTransport") private var controlPanelShowsTransport = true
    @AppStorage("controlPanelShowsScenes") private var controlPanelShowsScenes = true
    @Environment(\.colorScheme) private var colorScheme
    @State private var isShowingYouTubeAuthorization = false
    @AppStorage("openRouter.model") private var selectedAssistantModel = OpenRouterAssistantClient.defaultModel
    @State private var assistantKeyInput = ""
    @State private var hasAssistantKey = false
    @State private var assistantModels: [OpenRouterAssistantModel] = []
    @State private var assistantStatus: String?
    @State private var isLoadingAssistantModels = false

    private var isLocked: Bool { model.snapshot.areRecordingSettingsLocked }
    private var windowTab: SettingsTab {
        get { SettingsTab(rawValue: selectedSettingsTabRaw) ?? .general }
        nonmutating set { selectedSettingsTabRaw = newValue.rawValue }
    }

    var body: some View {
        Group {
            if embedded {
                selectedSettings(for: selectedTab)
                    .frame(maxWidth: 720, maxHeight: .infinity, alignment: .topLeading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 18)
                    .padding(.top, 22)
                    .navigationTitle(selectedTab.title)
            } else {
                HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Studio Recorder")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.top, 34)
                        .padding(.bottom, 12)
                    ForEach(SettingsTab.allCases, id: \.self) { tab in
                        Button {
                            windowTab = tab
                        } label: {
                            Label(tab.title, systemImage: tab.icon)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 8)
                                .background(
                                    windowTab == tab ? settingsRaised : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Text("LOCAL-FIRST MEDIA")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(16)
                }
                .padding(.horizontal, 8)
                .frame(width: 198)
                .background(settingsPanel)

                Divider()

                VStack(alignment: .leading, spacing: 0) {
                    Text(windowTab.title)
                        .font(.title2.weight(.semibold))
                        .padding(.horizontal, 22)
                        .padding(.top, 32)
                        .padding(.bottom, 8)
                    selectedSettings(for: windowTab)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 18)
                }
                .background(settingsContent)
            }
                .frame(width: 760, height: 540)
                .tint(Color(red: 0.90, green: 0.40, blue: 0.36))
            }
        }
        .sheet(isPresented: $isShowingYouTubeAuthorization) {
            YouTubeAuthorizationDisclosureView {
                Task { await managedYouTube.connect(clientID: streamingSettings.oauthClientID) }
            }
        }
    }

    private var settingsContent: Color {
        colorScheme == .dark
            ? Color(red: 0.055, green: 0.058, blue: 0.062)
            : Color(red: 0.95, green: 0.945, blue: 0.935)
    }

    private var settingsPanel: Color {
        colorScheme == .dark
            ? Color(red: 0.085, green: 0.088, blue: 0.094)
            : Color(red: 0.98, green: 0.975, blue: 0.965)
    }

    private var settingsRaised: Color {
        colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.07)
    }

    @ViewBuilder
    private func selectedSettings(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: generalSettings
        case .assistant: assistantSettings
        case .audio: audioSettings
        case .streaming: streamingSettingsView
        case .storage: storageSettings
        case .shortcuts: shortcutsSettings
        }
    }

    private var generalSettings: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: appearanceBinding) {
                    Text("System").tag(AppearancePreference.system)
                    Text("Light").tag(AppearancePreference.light)
                    Text("Dark").tag(AppearancePreference.dark)
                }
                .pickerStyle(.segmented)
                Text("Applies immediately to the Studio Recorder interface.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var assistantSettings: some View {
        Form {
            Section("OpenRouter") {
                SecureField("API key", text: $assistantKeyInput)
                    .textContentType(.password)
                HStack {
                    Button("Save key") { saveAssistantKey() }
                        .disabled(assistantKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove key") { removeAssistantKey() }
                        .disabled(!hasAssistantKey)
                    Text(hasAssistantKey ? "Key saved in Keychain" : "No key saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Requests send transcript text and timing IDs for the chosen scope. Raw audio and video stay on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Model") {
                Picker("Structured reply model", selection: $selectedAssistantModel) {
                    if assistantModels.isEmpty {
                        Text(selectedAssistantModel).tag(selectedAssistantModel)
                    } else {
                        ForEach(assistantModels) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                }
                .disabled(assistantModels.isEmpty)
                Button(isLoadingAssistantModels ? "Checking…" : "Refresh compatible models") {
                    Task { await refreshAssistantModels() }
                }
                .disabled(!hasAssistantKey || isLoadingAssistantModels)
                if let assistantStatus {
                    Text(assistantStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { loadAssistantKeyStatus() }
    }

    private func loadAssistantKeyStatus() {
        do {
            hasAssistantKey = try OpenRouterAssistantKeyStore().load() != nil
        } catch {
            assistantStatus = error.localizedDescription
        }
    }

    private func saveAssistantKey() {
        do {
            try OpenRouterAssistantKeyStore().save(assistantKeyInput)
            assistantKeyInput = ""
            hasAssistantKey = true
            assistantStatus = nil
            Task { await refreshAssistantModels() }
        } catch {
            assistantStatus = error.localizedDescription
        }
    }

    private func removeAssistantKey() {
        do {
            try OpenRouterAssistantKeyStore().delete()
            assistantKeyInput = ""
            hasAssistantKey = false
            assistantModels = []
            assistantStatus = nil
        } catch {
            assistantStatus = error.localizedDescription
        }
    }

    private func refreshAssistantModels() async {
        isLoadingAssistantModels = true
        defer { isLoadingAssistantModels = false }
        do {
            guard let key = try OpenRouterAssistantKeyStore().load() else {
                throw OpenRouterAssistantError.missingKey
            }
            assistantModels = try await OpenRouterAssistantClient().availableModels(apiKey: key)
            if assistantModels.isEmpty {
                assistantStatus = "No compatible text model is available for this key."
            } else {
                if !assistantModels.contains(where: { $0.id == selectedAssistantModel }) {
                    selectedAssistantModel = assistantModels[0].id
                }
                assistantStatus = "\(assistantModels.count) compatible models available."
            }
        } catch {
            assistantModels = []
            assistantStatus = error.localizedDescription
        }
    }

    private var audioSettings: some View {
        Form {
            lockedNotice
            Section("Sources") {
                Toggle("Capture system audio", isOn: systemAudioBinding)
                Toggle("Capture microphone", isOn: microphoneCaptureBinding)
                Picker("Default microphone", selection: microphoneBinding) {
                    Text("System Default").tag(String?.none)
                    ForEach(model.snapshot.availableMicrophones) { microphone in
                        Text(microphone.isSystemDefault ? "\(microphone.name) — System Default" : microphone.name)
                            .tag(Optional(microphone.id))
                    }
                    if let missingMicrophoneID {
                        Text("Missing device — \(missingMicrophoneID)")
                            .tag(Optional(missingMicrophoneID))
                    }
                }
                .disabled(
                    !preferencesStore.preferences.audio.capturesMicrophone ||
                        model.snapshot.availableMicrophones.isEmpty
                )
                if missingMicrophoneID != nil {
                    Label(
                        model.snapshot.availableMicrophones.isEmpty
                            ? "The saved microphone is unavailable, and no fallback microphone is currently available."
                            : "The saved microphone is unavailable. New drafts visibly fall back to the current system default.",
                        systemImage: "exclamationmark.triangle"
                    )
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if preferencesStore.preferences.audio.capturesMicrophone,
                          model.snapshot.availableMicrophones.isEmpty {
                    Label("No microphone is currently available. New drafts will report the missing-device state.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Toggle("Exclude app audio", isOn: excludeAppAudioBinding)
            }
            .disabled(isLocked)
        }
        .formStyle(.grouped)
    }

    private var storageSettings: some View {
        Form {
            lockedNotice
            Section("New projects") {
                LabeledContent("Save new projects to") {
                    Text(preferencesStore.destination.url.path(percentEncoded: false))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if let capacity = preferencesStore.destination.availableCapacity {
                    LabeledContent("Free space", value: ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file))
                }
                storageStatus
                HStack {
                    Button("Choose…", action: chooseDestination)
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([preferencesStore.destination.url])
                    }
                }
            }
            .disabled(isLocked)
        }
        .formStyle(.grouped)
    }

    private var streamingSettingsView: some View {
        Form {
            Section("YouTube Account") {
                HStack {
                    if managedYouTube.isAuthorized {
                        Button("Disconnect YouTube") {
                            Task { await managedYouTube.disconnect() }
                        }
                    } else {
                        Button("Connect YouTube") {
                            isShowingYouTubeAuthorization = true
                        }
                        .disabled(!streamingSettings.isManagedYouTubeConfigured)
                    }
                    Text(managedYouTube.isAuthorized ? "Connected to YouTube" : managedYouTube.state.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if managedYouTube.pendingSession != nil {
                    HStack {
                        Button("Resume in Recording Studio") {
                            model.send(.selectRoute(.studio))
                        }
                        Button("End YouTube event") {
                            Task { await managedYouTube.complete(clientID: streamingSettings.oauthClientID) }
                        }
                        Button("Open Live Control Room") {
                            NSWorkspace.shared.open(URL(string: "https://studio.youtube.com/")!)
                        }
                    }
                }
                if !streamingSettings.isManagedYouTubeConfigured {
                    Label("YouTube connection is not configured in this build.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Authorization opens in your browser. OAuth tokens stay in macOS Keychain; managed stream keys stay in memory only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Stream Quality") {
                LabeledContent("Video bitrate") {
                    Picker("Video bitrate", selection: $streamingSettings.videoBitRate) {
                        Text("6 Mbps").tag(6_000_000)
                        Text("8 Mbps").tag(8_000_000)
                        Text("10 Mbps").tag(10_000_000)
                        Text("12 Mbps").tag(12_000_000)
                        Text("20 Mbps").tag(20_000_000)
                        Text("24 Mbps").tag(24_000_000)
                        Text("30 Mbps · 4K30").tag(30_000_000)
                        Text("35 Mbps").tag(35_000_000)
                        Text("40 Mbps").tag(40_000_000)
                    }
                    .labelsHidden()
                }
                LabeledContent("Audio bitrate") {
                    Picker("Audio bitrate", selection: $streamingSettings.audioBitRate) {
                        Text("128 Kbps").tag(128_000)
                        Text("192 Kbps").tag(192_000)
                        Text("256 Kbps").tag(256_000)
                    }
                    .labelsHidden()
                }
                if activeCanvasIs4K {
                    Label("4K Scene active. Use \(recommended4KBitRate / 1_000_000) Mbps for \(activeFrameRate) fps and Normal latency in YouTube.", systemImage: "4k.tv")
                        .font(.caption)
                        .foregroundStyle(streamingSettings.videoBitRate >= recommended4KBitRate ? Color.secondary : Color.orange)
                }
                Button("Save settings") { streamingSettings.save() }
            }
            Section("Advanced") {
                Toggle("Use a custom stream key", isOn: customStreamKeyBinding)
                    .disabled(managedYouTube.pendingSession != nil)
                if !streamingSettings.usesManagedYouTube {
                    TextField("RTMPS server", text: $streamingSettings.serverURL)
                        .textContentType(.URL)
                    SecureField("Stream key", text: $streamingSettings.streamKey)
                        .textContentType(.password)
                    HStack {
                        Button("Save stream key") { streamingSettings.save() }
                        Button("Open YouTube Live Control Room") {
                            NSWorkspace.shared.open(URL(string: "https://studio.youtube.com/")!)
                        }
                    }
                    Text("The custom stream key is stored only in macOS Keychain. It is never written to project files or logs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let credentialError = streamingSettings.credentialError {
                    Label(credentialError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section("YouTube encoder contract") {
                LabeledContent("Video", value: "H.264 · \(activeFrameRate) fps · 2 s keyframes")
                LabeledContent("Audio", value: "AAC · \(streamingSettings.audioBitRate / 1_000) Kbps")
                Text("The active Scene determines horizontal, vertical, 4K, or custom stream dimensions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Go live") {
                Label("Connect your YouTube account and choose a scheduled broadcast in Recording Studio.", systemImage: "1.circle")
                Label("Choose Stream and run the preflight before starting.", systemImage: "2.circle")
                Label("Studio Recorder creates or binds the YouTube stream automatically.", systemImage: "3.circle")
                Label("Confirm the preview and stream health in YouTube Live Control Room.", systemImage: "4.circle")
                Text("For a scheduled stream, YouTube requires a final Go live action in Live Control Room. 4K uses normal latency.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var customStreamKeyBinding: Binding<Bool> {
        Binding(
            get: { !streamingSettings.usesManagedYouTube },
            set: {
                streamingSettings.usesManagedYouTube = !$0
                streamingSettings.save()
            }
        )
    }

    private var shortcutsSettings: some View {
        Form {
            Section("Recording Controls window") {
                Toggle("Show recording controls", isOn: $controlPanelShowsTransport)
                Toggle("Show saved scenes", isOn: $controlPanelShowsScenes)
                shortcut("Open Recording Controls", keys: "⌘⇧C")
                Text("This floating window is protected from screen capture and stays available over other apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Keyboard shortcuts") {
                shortcut("New Recording", keys: "⌘N")
                shortcut("Record / Stop in Studio", keys: "⌘R")
                shortcut("Pause / Resume Recording", keys: "⌘⇧P")
                shortcut("Switch to Scene 1–9", keys: "⌥1–⌥9")
                shortcut("Search Projects", keys: "⌘F")
                shortcut("Settings", keys: "⌘,")
                shortcut("Dismiss dialog or sheet", keys: "Esc")
            }
        }
        .formStyle(.grouped)
    }

    private var activeCanvasIs4K: Bool {
        let canvas = model.snapshot.studioDraft?.presentation.canvas
            ?? CaptureCanvasSnapshot(preset: preferencesStore.preferences.capture.programPreset)
        return canvas.width >= 3_840 || canvas.height >= 3_840
    }

    private var recommended4KBitRate: Int {
        activeFrameRate > 30 ? 35_000_000 : 30_000_000
    }

    private var activeFrameRate: Int {
        model.snapshot.studioDraft?.frameRate ?? preferencesStore.preferences.capture.frameRate
    }

    @ViewBuilder
    private var lockedNotice: some View {
        if isLocked {
            Section {
                Label("Applies to new sessions; locked while recording.", systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var storageStatus: some View {
        switch preferencesStore.destination.warning {
        case .bookmarkUnavailable:
            Label("The saved folder could not be resolved. New projects use Movies/Studio Recorder.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .bookmarkStale:
            Label("The saved folder bookmark is stale. New projects use Movies/Studio Recorder.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .unwritable:
            Label("This folder is not writable. Choose another folder before recording.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        case nil:
            Label("Folder is available for new projects.", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private var missingMicrophoneID: String? {
        guard let savedID = preferencesStore.preferences.audio.microphoneDeviceID,
              !model.snapshot.availableMicrophones.contains(where: { $0.id == savedID }) else {
            return nil
        }
        return savedID
    }

    private var appearanceBinding: Binding<AppearancePreference> {
        Binding(
            get: { preferencesStore.preferences.appearance },
            set: { model.send(.changePreference(.appearance($0))) }
        )
    }

    private var systemAudioBinding: Binding<Bool> {
        preferenceBinding(
            get: { preferencesStore.preferences.audio.capturesSystemAudio },
            change: PreferenceChange.capturesSystemAudio
        )
    }

    private var microphoneCaptureBinding: Binding<Bool> {
        preferenceBinding(
            get: { preferencesStore.preferences.audio.capturesMicrophone },
            change: PreferenceChange.capturesMicrophone
        )
    }

    private var microphoneBinding: Binding<String?> {
        Binding(
            get: { preferencesStore.preferences.audio.microphoneDeviceID },
            set: { model.send(.changePreference(.microphoneDeviceID($0))) }
        )
    }

    private var excludeAppAudioBinding: Binding<Bool> {
        preferenceBinding(
            get: { preferencesStore.preferences.audio.excludeStudioRecorderAudio },
            change: PreferenceChange.excludeStudioRecorderAudio
        )
    }

    private func preferenceBinding(
        get: @escaping @Sendable () -> Bool,
        change: @escaping @Sendable (Bool) -> PreferenceChange
    ) -> Binding<Bool> {
        Binding(get: get, set: { model.send(.changePreference(change($0))) })
    }

    private func shortcut(_ title: String, keys: String) -> some View {
        LabeledContent(title) {
            Text(keys)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
                .accessibilityLabel(keys)
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "Choose Project Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = preferencesStore.destination.url
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.send(.setProjectDestination(url))
    }
}
