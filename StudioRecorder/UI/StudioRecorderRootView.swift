import AVFoundation
import SwiftUI

struct StudioRecorderRootView: View {
    @ObservedObject var model: StudioRecorderModel
    @StateObject private var liveScene = LiveSceneCoordinator()

    private let coral = Color(red: 0.90, green: 0.40, blue: 0.36)

    private var snapshot: StudioRecorderSnapshot { model.snapshot }

    var body: some View {
        NavigationSplitView {
            List(selection: routeSelection) {
                Section {
                    Label("Studio Recorder", systemImage: "pause.rectangle.fill")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .listRowBackground(Color.clear)
                }

                Section {
                    Label("Projects", systemImage: "folder")
                        .tag(MainRoute.projects)
                    Label("Studio", systemImage: "record.circle")
                        .tag(MainRoute.studio)
                }

                if !snapshot.interruptedProjects.isEmpty {
                    Section("Attention") {
                        Label("Recovery", systemImage: "lifepreserver")
                            .badge(snapshot.interruptedProjects.count)
                            .tag(MainRoute.recovery)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 210, ideal: 224, max: 260)
        } detail: {
            Group {
                switch snapshot.route {
                case .projects:
                    projectsView
                case .studio:
                    studioDestination
                case .recovery:
                    recoveryView
                }
            }
            .toolbar { toolbarContent }
        }
        .tint(coral)
        .preferredColorScheme(.dark)
        .task {
            await model.launch()
            liveScene.startCameraPreview()
        }
    }

    private var routeSelection: Binding<MainRoute?> {
        Binding(
            get: { snapshot.route },
            set: { route in
                if let route {
                    model.send(.selectRoute(route))
                }
            }
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if snapshot.route == .studio {
                HStack(spacing: 7) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(snapshot.captureState.label).foregroundStyle(.secondary)
                }
                .font(.subheadline)
            } else {
                Text(snapshot.route == .recovery ? "Recovery" : "Projects")
                    .font(.headline)
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if snapshot.route == .projects {
                Button {
                    model.send(.newRecording)
                } label: {
                    Label("New Recording", systemImage: "plus")
                }
            }
        }
    }

    private var projectsView: some View {
        Group {
            if snapshot.projects.isEmpty {
                ContentUnavailableView {
                    Label("No projects yet", systemImage: "record.circle")
                } description: {
                    Text("Each recording becomes a recoverable package with raw tracks and an append-only journal.")
                } actions: {
                    Button("New Recording") { model.send(.newRecording) }
                        .buttonStyle(.borderedProminent)
                        .tint(coral)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Your projects").font(.largeTitle.weight(.semibold))
                            Text("Raw tracks stay recoverable. Layout and cuts remain non-destructive.")
                                .foregroundStyle(.secondary)
                        }

                        if !snapshot.interruptedProjects.isEmpty {
                            Button {
                                model.send(.selectRoute(.recovery))
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "exclamationmark.triangle")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(snapshot.interruptedProjects.count) recording needs recovery review")
                                            .fontWeight(.semibold)
                                        Text("The package is preserved and ready for inspection.")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption.weight(.bold))
                                }
                                .padding(14)
                                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.orange)
                        }

                        Text("Recent recordings")
                            .font(.headline)
                            .padding(.top, 2)

                        VStack(spacing: 0) {
                            ForEach(Array(snapshot.projects.enumerated()), id: \.element.id) { index, project in
                                ProjectRow(project: project)
                                if index < snapshot.projects.count - 1 {
                                    Divider().padding(.leading, 108)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(24)
                }
                .navigationTitle("Projects")
            }
        }
    }

    @ViewBuilder
    private var studioDestination: some View {
        if snapshot.availableDisplays.isEmpty, case .failed = snapshot.captureState {
            permissionRepairView
        } else {
            studioView
        }
    }

    private var permissionRepairView: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "pause.rectangle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(coral)
                Text("Your recording desk needs access.")
                    .font(.largeTitle.weight(.semibold))
                Text("Screen Recording is required to discover and record selected displays. Nothing starts in the background.")
                    .foregroundStyle(.secondary)
                Spacer()
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay(Image(systemName: "rectangle.inset.filled").font(.largeTitle).foregroundStyle(.secondary))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(40)

            VStack(alignment: .leading, spacing: 18) {
                Text("CAPTURE CHECK").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("Allow Screen Recording")
                    .font(.title2.weight(.semibold))
                Text("When you return, choose Check Again to refresh access before recording.")
                    .foregroundStyle(.secondary)
                Divider()
                Label("Screen Recording is unavailable", systemImage: "display")
                Label("Microphone is configured in the capture stream", systemImage: "mic")
                    .foregroundStyle(.secondary)
                Label("Camera is a later capture slice", systemImage: "video")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open System Settings") {
                    model.openScreenRecordingSettings()
                }
                .buttonStyle(.borderedProminent)
                .tint(coral)
                Button("Check Again") {
                    Task { await model.refreshCaptureSources() }
                }
                .buttonStyle(.bordered)
            }
            .frame(width: 390, alignment: .leading)
            .padding(40)
            .background(.thinMaterial)
        }
        .navigationTitle("Capture access")
    }

    private var studioView: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Program preview").font(.headline)
                        Spacer()
                        Text("1920 × 1080  ·  30 fps")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("Preview contract")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                    LiveProgramPreview(
                        screenImage: liveScene.screenImage,
                        cameraSession: liveScene.cameraSession,
                        selectedDisplayName: selectedDisplayName,
                        isRecording: snapshot.captureState == .recording
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .task(id: primarySelectedDisplayID) {
                            guard let primarySelectedDisplayID else { return }
                            await liveScene.startScreenPreview(for: primarySelectedDisplayID)
                        }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                StudioInspector(
                    displays: snapshot.availableDisplays,
                    selectedDisplayIDs: Binding(
                        get: { snapshot.selectedDisplayIDs },
                        set: { model.send(.setSelectedDisplayIDs($0)) }
                    ),
                    cameras: liveScene.cameras,
                    selectedCameraID: Binding(
                        get: { liveScene.selectedCameraID },
                        set: { liveScene.selectCamera($0) }
                    ),
                    isLocked: snapshot.captureState == .recording || snapshot.captureState == .stopping
                )
                .frame(width: 304)
                .background(.bar)
            }

            Divider()
            HStack(spacing: 16) {
                Label("Microphone is clear", systemImage: "mic")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button(action: toggleRecording) {
                    Label(recordButtonTitle, systemImage: snapshot.captureState == .recording ? "stop.fill" : "record.circle.fill")
                        .frame(minWidth: 122)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(snapshot.captureState == .recording ? .red : coral)
                .disabled(!canToggleRecording)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Movies/Studio Recorder").font(.caption.weight(.medium))
                    Text("Recoverable project packages").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(.bar)
        }
        .navigationTitle("Studio")
    }

    private var recoveryView: some View {
        Group {
            if snapshot.interruptedProjects.isEmpty {
                ContentUnavailableView("No recovery needed", systemImage: "checkmark.shield", description: Text("All discovered projects closed cleanly."))
            } else {
                List(snapshot.interruptedProjects) { project in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(project.rootURL.deletingPathExtension().lastPathComponent).fontWeight(.semibold)
                        Text("\(project.displayCount) display track(s) · \(project.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("The package is preserved for per-track review in the next recovery slice.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Recovery")
    }

    private var canToggleRecording: Bool {
        !snapshot.isCaptureCommandInFlight && (snapshot.captureState == .ready || snapshot.captureState == .recording)
    }

    private var recordButtonTitle: String {
        snapshot.captureState == .recording ? "Stop" : "Record"
    }

    private var statusColor: Color {
        switch snapshot.captureState {
        case .recording: .red
        case .failed: .orange
        case .ready: .green
        case .preparing, .stopping: .secondary
        }
    }

    private var primarySelectedDisplayID: UInt32? {
        snapshot.availableDisplays.first(where: { snapshot.selectedDisplayIDs.contains($0.id) })?.id
    }

    private var selectedDisplayName: String {
        snapshot.availableDisplays.first(where: { $0.id == primarySelectedDisplayID })?.title ?? "Selected display"
    }

    private func toggleRecording() {
        model.send(.toggleRecording)
    }
}

private struct ProjectRow: View {
    let project: RecordingProjectSnapshot

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 7)
                .fill(statusColor.opacity(0.18))
                .frame(width: 92, height: 54)
                .overlay(Image(systemName: statusIcon).foregroundStyle(statusColor))
            VStack(alignment: .leading, spacing: 4) {
                Text("Recording · \(project.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .fontWeight(.medium)
                Text("\(project.displayCount) display\(project.displayCount == 1 ? "" : "s") · \(project.captureProfile)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(project.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            Text(statusLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(statusColor)
        }
        .padding(.vertical, 3)
    }

    private var statusLabel: String {
        switch project.lifecycle {
        case .recording: "Recording"
        case .finalizing: "Finalizing"
        case .finalized: "Finalized"
        case .needsRecovery: "Needs recovery"
        case .unreadable: "Unreadable"
        }
    }

    private var statusColor: Color {
        switch project.lifecycle {
        case .finalized: .green
        case .needsRecovery, .unreadable: .orange
        case .recording, .finalizing: .secondary
        }
    }

    private var statusIcon: String {
        switch project.lifecycle {
        case .finalized: "display.2"
        case .needsRecovery, .unreadable: "exclamationmark.triangle"
        case .recording: "record.circle"
        case .finalizing: "clock"
        }
    }
}

private struct StudioInspector: View {
    let displays: [AvailableDisplay]
    @Binding var selectedDisplayIDs: Set<UInt32>
    let cameras: [AvailableCamera]
    @Binding var selectedCameraID: String?
    let isLocked: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                inspectorHeader("Sources")
                ForEach(displays) { display in
                    Toggle(isOn: binding(for: display.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(display.title).font(.subheadline.weight(.medium))
                            Text("\(Int(display.pixelSize.width)) × \(Int(display.pixelSize.height)) native capture")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(isLocked)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    Divider()
                }

                sourceRow("System audio", detail: "Primary display track", icon: "speaker.wave.2")
                sourceRow("Microphone", detail: "Embedded once in primary capture", icon: "mic")
                cameraRow

                Divider().padding(.top, 4)
                inspectorHeader("Capture")
                contractRow("Frame rate", value: "30 fps")
                contractRow("Codec", value: "HEVC · H.264 fallback")
                contractRow("Cursor", value: "Included")

                Divider().padding(.top, 4)
                inspectorHeader("Resilience")
                Text("Raw tracks and an append-only journal are written into one recoverable project package.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.bottom, 18)
            }
        }
    }

    @ViewBuilder
    private var cameraRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "video").foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("Camera").font(.subheadline.weight(.medium))
                Text(cameras.isEmpty ? "No camera available" : "Live preview only — capture next slice")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if cameras.isEmpty {
                Text("Unavailable").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            } else {
                Picker("Camera", selection: $selectedCameraID) {
                    ForEach(cameras) { camera in
                        Text(camera.name).tag(Optional(camera.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 122)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func inspectorHeader(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 14)
    }

    private func sourceRow(_ title: String, detail: String, icon: String, trailing: String? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if let trailing {
                Text(trailing).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            } else {
                Circle().fill(title == "Microphone" ? .green : .secondary).frame(width: 7, height: 7)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func contractRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.monospacedDigit())
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func binding(for id: UInt32) -> Binding<Bool> {
        Binding(
            get: { selectedDisplayIDs.contains(id) },
            set: { isSelected in
                if isSelected { selectedDisplayIDs.insert(id) }
                else { selectedDisplayIDs.remove(id) }
            }
        )
    }
}

private struct LiveProgramPreview: View {
    let screenImage: NSImage?
    let cameraSession: AVCaptureSession?
    let selectedDisplayName: String
    let isRecording: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.72))
            if let screenImage {
                Image(nsImage: screenImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(6)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "rectangle.on.rectangle.angled")
                        .font(.system(size: 44))
                    Text("Loading (selectedDisplayName)…").font(.headline)
                    Text("The selected screen will appear before recording starts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let cameraSession {
                CameraLivePreview(session: cameraSession)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.5), lineWidth: 1))
                    .frame(width: 180, height: 102)
                    .padding(20)
                    .accessibilityLabel("Selected camera preview")
            }

            if isRecording {
                Label("REC", systemImage: "record.circle.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.red)
                    .padding(10)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(isRecording ? Color.red : Color.clear, lineWidth: 1)
        }
        .accessibilityLabel("Live selected screen and camera preview")
    }
}
