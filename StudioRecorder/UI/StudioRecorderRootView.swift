import SwiftUI

private enum StudioSection: Hashable {
    case record
    case layouts
    case recovery
}

private enum LayoutPreset: String, CaseIterable, Identifiable {
    case screenFocus = "Screen focus"
    case cameraOverlay = "Camera overlay"
    case split = "Split 70 / 30"
    case equal = "50 / 50"
    case presenter = "Presenter"

    var id: String { rawValue }
}

struct StudioRecorderRootView: View {
    @StateObject private var coordinator = RecordingCoordinator()
    @State private var section: StudioSection? = .record
    @State private var selectedDisplayIDs: Set<UInt32> = []
    @State private var preset: LayoutPreset = .cameraOverlay

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Section("Studio") {
                    Label("Record", systemImage: "record.circle")
                        .tag(StudioSection.record)
                    Label("Layouts", systemImage: "rectangle.3.group")
                        .tag(StudioSection.layouts)
                }
                Section("Project") {
                    Label("Recovery", systemImage: "lifepreserver")
                        .tag(StudioSection.recovery)
                }
            }
            .navigationTitle("Studio Recorder")
            .listStyle(.sidebar)
        } detail: {
            Group {
                switch section ?? .record {
                case .record:
                    recordView
                case .layouts:
                    layoutsView
                case .recovery:
                    recoveryView
                }
            }
            .toolbar { toolbarContent }
        }
        .task {
            await coordinator.refreshDisplays()
            selectedDisplayIDs = Set(coordinator.availableDisplays.map(\.id))
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleRecording)) { _ in
            toggleRecording()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(coordinator.state.label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: toggleRecording) {
                Label(recordButtonTitle, systemImage: coordinator.state == .recording ? "stop.fill" : "record.circle.fill")
            }
            .tint(coordinator.state == .recording ? .red : .accentColor)
            .disabled(!canToggleRecording)
        }
    }

    private var recordView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recording desk")
                            .font(.largeTitle.weight(.semibold))
                        Text("Raw display tracks are saved natively; the program edit stays non-destructive.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if coordinator.state == .recording {
                        Text(durationText)
                            .font(.title2.monospacedDigit().weight(.medium))
                    }
                }

                ProgramPreview(preset: preset, isRecording: coordinator.state == .recording)

                HStack(alignment: .top, spacing: 16) {
                    GroupBox("Captured displays") {
                        VStack(alignment: .leading, spacing: 10) {
                            if coordinator.availableDisplays.isEmpty {
                                Text("Checking Screen Recording access…")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(coordinator.availableDisplays) { display in
                                Toggle(isOn: displayBinding(for: display.id)) {
                                    VStack(alignment: .leading) {
                                        Text(display.title)
                                        Text("\(Int(display.pixelSize.width)) × \(Int(display.pixelSize.height)) native capture")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .disabled(coordinator.state == .recording || coordinator.state == .stopping)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    GroupBox("Tracks") {
                        VStack(alignment: .leading, spacing: 10) {
                            TrackRow(icon: "display", title: "Screen", detail: "One raw .mov per selected display")
                            TrackRow(icon: "waveform", title: "System audio", detail: "Embedded once in the primary screen capture")
                            TrackRow(icon: "mic", title: "Microphone", detail: "Embedded once in the primary screen capture")
                            TrackRow(icon: "video", title: "Camera", detail: "Next capture slice")
                        }
                        .padding(.vertical, 4)
                    }
                }

                GroupBox("Recording resilience") {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "externaldrive.badge.checkmark")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Project journal enabled")
                                .fontWeight(.medium)
                            Text("Each raw track starts in a .recordingproject package under Movies/Studio Recorder. The journal records started, completed, and failed tracks for recovery review.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(24)
        }
        .navigationTitle("Record")
    }

    private var layoutsView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Layouts")
                .font(.largeTitle.weight(.semibold))
            Text("Choose a program preset now; later editing changes only the composed program output, never the raw tracks.")
                .foregroundStyle(.secondary)
            Picker("Program layout", selection: $preset) {
                ForEach(LayoutPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .pickerStyle(.radioGroup)
            ProgramPreview(preset: preset, isRecording: false)
            Spacer()
        }
        .padding(24)
        .navigationTitle("Layouts")
    }

    private var recoveryView: some View {
        Group {
            if coordinator.interruptedProjects.isEmpty {
                ContentUnavailableView(
                    "No interrupted projects found",
                    systemImage: "checkmark.shield",
                    description: Text("The project directory was scanned for recording packages that did not close cleanly.")
                )
            } else {
                List(coordinator.interruptedProjects) { project in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.rootURL.lastPathComponent)
                            .fontWeight(.medium)
                        Text("\(project.displays.count) display track(s) · \(project.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Recovery")
    }

    private var canToggleRecording: Bool {
        coordinator.state == .ready || coordinator.state == .recording
    }

    private var recordButtonTitle: String {
        coordinator.state == .recording ? "Stop" : "Record"
    }

    private var statusColor: Color {
        switch coordinator.state {
        case .recording: .red
        case .failed: .orange
        case .ready: .green
        case .preparing, .stopping: .secondary
        }
    }

    private var durationText: String {
        let total = Int(coordinator.recordedDuration)
        return String(format: "%02d:%02d:%02d", total / 3_600, (total / 60) % 60, total % 60)
    }

    private func displayBinding(for id: UInt32) -> Binding<Bool> {
        Binding(
            get: { selectedDisplayIDs.contains(id) },
            set: { isSelected in
                if isSelected {
                    selectedDisplayIDs.insert(id)
                } else {
                    selectedDisplayIDs.remove(id)
                }
            }
        )
    }

    private func toggleRecording() {
        if coordinator.state == .recording {
            Task { await coordinator.stopRecording() }
        } else if coordinator.state == .ready {
            Task { await coordinator.startRecording(selectedDisplayIDs: selectedDisplayIDs) }
        }
    }
}

private struct ProgramPreview: View {
    let preset: LayoutPreset
    let isRecording: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 14)
                .fill(.black.gradient)
                .overlay {
                    VStack(spacing: 10) {
                        Image(systemName: "display.2")
                            .font(.system(size: 38))
                        Text("1080p program preview")
                            .font(.headline)
                        Text(isRecording ? "Program layout is preview-only in this capture slice" : preset.rawValue)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    .foregroundStyle(.white)
                }

            if preset != .screenFocus {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.gray.opacity(0.8))
                    .overlay(Image(systemName: "person.fill").foregroundStyle(.white))
                    .frame(width: 160, height: 90)
                    .padding(16)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .accessibilityLabel("1080p program preview")
    }
}

private struct TrackRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
