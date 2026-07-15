import AppKit
import SwiftUI

private enum SettingsTab: String, CaseIterable {
    case general
    case capture
    case audio
    case streaming
    case storage
    case shortcuts
}

private struct SettingsFrameModifier: ViewModifier {
    let embedded: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if embedded {
            content
                .frame(maxWidth: 900, maxHeight: .infinity)
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content.frame(width: 620, height: 460)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: StudioRecorderModel
    @ObservedObject var preferencesStore: PreferencesStore
    @ObservedObject var streamingSettings: YouTubeStreamingSettingsStore
    var embedded = false
    @AppStorage("selectedSettingsTab") private var selectedTab = SettingsTab.general.rawValue

    private var isLocked: Bool { model.snapshot.areRecordingSettingsLocked }

    var body: some View {
        settingsTabs
            .modifier(SettingsFrameModifier(embedded: embedded))
            .padding(.top, embedded ? 22 : 8)
            .navigationTitle("Settings")
    }

    private var settingsTabs: some View {
        TabView(selection: $selectedTab) {
            generalSettings
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general.rawValue)
            captureSettings
                .tabItem { Label("Capture", systemImage: "display") }
                .tag(SettingsTab.capture.rawValue)
            audioSettings
                .tabItem { Label("Audio", systemImage: "waveform") }
                .tag(SettingsTab.audio.rawValue)
            streamingSettingsView
                .tabItem { Label("Streaming", systemImage: "dot.radiowaves.left.and.right") }
                .tag(SettingsTab.streaming.rawValue)
            storageSettings
                .tabItem { Label("Storage", systemImage: "internaldrive") }
                .tag(SettingsTab.storage.rawValue)
            shortcutsSettings
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag(SettingsTab.shortcuts.rawValue)
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

    private var captureSettings: some View {
        Form {
            lockedNotice
            Section("Video profile") {
                LabeledContent("Frame rate", value: "30 fps")
                Picker("Codec policy", selection: codecBinding) {
                    Text("Automatic (HEVC → H.264)").tag(RecordingCodecPolicy.automatic)
                    Text("H.264").tag(RecordingCodecPolicy.h264)
                }
                Picker("New Scene output", selection: programPresetBinding) {
                    ForEach(CaptureCanvasPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                Text("The Scene output is the exact program recording, export, and stream resolution. Editable raw display tracks keep native resolution.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(isLocked)
            Section("Capture behavior") {
                Toggle("Include cursor", isOn: includeCursorBinding)
                Toggle("Exclude Studio Recorder", isOn: excludeAppBinding)
            }
            .disabled(isLocked)
        }
        .formStyle(.grouped)
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
            Section("YouTube Live") {
                TextField("RTMPS server", text: $streamingSettings.serverURL)
                    .textContentType(.URL)
                SecureField("Stream key", text: $streamingSettings.streamKey)
                    .textContentType(.password)
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
                if activeCanvasIs4K {
                    Label("4K Scene active. Use 30 Mbps for 30 fps and Normal latency in YouTube.", systemImage: "4k.tv")
                        .font(.caption)
                        .foregroundStyle(streamingSettings.videoBitRate >= 30_000_000 ? Color.secondary : Color.orange)
                }
                HStack {
                    Button("Save to Keychain") { streamingSettings.save() }
                    Button("Open YouTube Live Control Room") {
                        NSWorkspace.shared.open(URL(string: "https://studio.youtube.com/channel/UC/livestreaming")!)
                    }
                }
                if let credentialError = streamingSettings.credentialError {
                    Label(credentialError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("The stream key is stored only in macOS Keychain. It is never written to project files or logs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("YouTube encoder contract") {
                LabeledContent("Video", value: "H.264 · 30 fps · 2 s keyframes")
                LabeledContent("Audio", value: "AAC · 128 Kbps")
                Text("The active Scene determines horizontal, vertical, 4K, or custom stream dimensions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var shortcutsSettings: some View {
        Form {
            Section("Keyboard shortcuts") {
                shortcut("New Recording", keys: "⌘N")
                shortcut("Record / Stop in Studio", keys: "⌘R")
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

    private var codecBinding: Binding<RecordingCodecPolicy> {
        Binding(
            get: { preferencesStore.preferences.capture.codecPolicy },
            set: { model.send(.changePreference(.codecPolicy($0))) }
        )
    }

    private var programPresetBinding: Binding<CaptureCanvasPreset> {
        Binding(
            get: { preferencesStore.preferences.capture.programPreset },
            set: { model.send(.changePreference(.programPreset($0))) }
        )
    }

    private var includeCursorBinding: Binding<Bool> {
        preferenceBinding(
            get: { preferencesStore.preferences.capture.includeCursor },
            change: PreferenceChange.includeCursor
        )
    }

    private var excludeAppBinding: Binding<Bool> {
        preferenceBinding(
            get: { preferencesStore.preferences.capture.excludeStudioRecorder },
            change: PreferenceChange.excludeStudioRecorder
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
