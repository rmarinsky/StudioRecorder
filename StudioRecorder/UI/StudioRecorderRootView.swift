import AppKit
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
        .task {
            await model.launch()
            await updateLiveScene(for: snapshot.route)
        }
        .onChange(of: snapshot.route) { _, route in
            Task { await updateLiveScene(for: route) }
        }
        .onChange(of: snapshot.captureState) { _, _ in
            Task { await updateLiveScene(for: snapshot.route) }
        }
        .onChange(of: snapshot.studioDraft?.cameraDeviceID) { _, _ in
            Task { await updateLiveScene(for: snapshot.route) }
        }
        .onChange(of: snapshot.capturesCamera) { _, _ in
            Task { await updateLiveScene(for: snapshot.route) }
        }
        .onDisappear {
            Task {
                await liveScene.stopCameraPreview()
                await liveScene.stopScreenPreview()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.appBecameActive() }
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
            if let selectedProject = snapshot.projects.first(where: { $0.id == snapshot.selectedProjectID }) {
                ProjectDetailView(
                    project: selectedProject,
                    onClose: { model.send(.closeProject) }
                )
                .id(selectedProject.id)
            } else if snapshot.projects.isEmpty {
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
                                Button {
                                    model.send(.openProject(project.id))
                                } label: {
                                    ProjectRow(project: project)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
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
        if snapshot.showsCaptureRepair {
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
                Text(permissionRepair.explanation)
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
                if permissionRepair.showsLoadingSkeleton {
                    Text("Checking permissions")
                        .font(.title2.weight(.semibold))
                    ProgressView()
                        .controlSize(.large)
                        .accessibilityLabel("Checking capture permissions")
                    VStack(alignment: .leading, spacing: 12) {
                        RoundedRectangle(cornerRadius: 5).fill(.quaternary).frame(height: 18)
                        RoundedRectangle(cornerRadius: 5).fill(.quaternary).frame(width: 230, height: 18)
                    }
                    .redacted(reason: .placeholder)
                    Spacer()
                } else {
                    Text(permissionRepair.title)
                        .font(.title2.weight(.semibold))
                    Text(permissionRepair.detail)
                        .foregroundStyle(.secondary)
                    Divider()
                    permissionStatusRow(
                        "Screen Recording",
                        label: permissionRepair.screenStatusLabel,
                        isGranted: snapshot.permissionSnapshot.screenRecording.isGranted,
                        icon: "display"
                    )
                    permissionStatusRow(
                        "Microphone",
                        label: permissionRepair.microphoneStatusLabel,
                        isGranted: snapshot.permissionSnapshot.microphone.isGranted,
                        icon: "mic"
                    )
                    permissionStatusRow(
                        "Camera",
                        label: permissionRepair.cameraStatusLabel,
                        isGranted: snapshot.permissionSnapshot.camera.isGranted,
                        icon: "video"
                    )
                    Spacer()

                    if permissionRepair.actions.contains(.requestAccess) {
                        Button(permissionRequestTitle) {
                            Task { await model.requestPermission(permissionRepair.permission) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(coral)
                    }

                    if permissionRepair.actions.contains(.openSystemSettings) {
                        Button("Open System Settings") {
                            model.openSystemSettings(for: permissionRepair.permission)
                        }
                        .buttonStyle(.bordered)
                    }

                    if permissionRepair.actions.contains(.recordWithoutMicrophone) {
                        Button("Record Without Microphone") {
                            model.send(.recordWithoutMicrophone)
                        }
                        .buttonStyle(.bordered)
                    }

                    if permissionRepair.actions.contains(.recordWithoutCamera) {
                        Button("Record Without Camera") {
                            model.send(.recordWithoutCamera)
                        }
                        .buttonStyle(.bordered)
                    }

                    if permissionRepair.actions.contains(.checkAgain) {
                        Button("Check Again") {
                            Task { await model.refreshCaptureSources() }
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if permissionRepair.actions.contains(.browseProjects) {
                    Button("Browse Existing Projects") {
                        model.send(.selectRoute(.projects))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 390, alignment: .leading)
            .padding(40)
            .background(.thinMaterial)
        }
        .navigationTitle("Capture access")
    }

    private var permissionRepair: PermissionRepairPresentation {
        guard let presentation = snapshot.permissionRepairPresentation else {
            preconditionFailure("Permission repair presentation requested outside repair state")
        }
        return presentation
    }

    private var permissionRequestTitle: String {
        switch permissionRepair.permission {
        case .screenRecording: "Allow Screen Recording"
        case .microphone: "Allow Microphone"
        case .camera: "Allow Camera"
        }
    }

    private func permissionStatusRow(_ title: String, label: String, isGranted: Bool, icon: String) -> some View {
        Label("\(title): \(label)", systemImage: icon)
            .foregroundStyle(isGranted ? .green : .secondary)
            .accessibilityLabel("\(title), \(label)")
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
                        screenPreviewError: liveScene.screenPreviewError,
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
                    microphones: snapshot.availableMicrophones,
                    capturesSystemAudio: Binding(
                        get: { snapshot.studioDraft?.capturesSystemAudio ?? true },
                        set: { model.send(.setDraftCapturesSystemAudio($0)) }
                    ),
                    cameras: snapshot.availableCameras,
                    selectedCameraID: Binding(
                        get: { snapshot.studioDraft?.cameraDeviceID },
                        set: { model.send(.setDraftCameraDeviceID($0)) }
                    ),
                    capturesCamera: Binding(
                        get: { snapshot.capturesCamera },
                        set: { model.send(.setCapturesCamera($0)) }
                    ),
                    capturesMicrophone: Binding(
                        get: { snapshot.capturesMicrophone },
                        set: { model.send(.setCapturesMicrophone($0)) }
                    ),
                    microphoneDeviceID: Binding(
                        get: { snapshot.studioDraft?.microphoneDeviceID },
                        set: { model.send(.setDraftMicrophoneDeviceID($0)) }
                    ),
                    microphoneFallback: snapshot.studioDraft?.microphoneFallback,
                    includeCursor: Binding(
                        get: { snapshot.studioDraft?.includeCursor ?? true },
                        set: { model.send(.setDraftIncludeCursor($0)) }
                    ),
                    excludeStudioRecorder: Binding(
                        get: { snapshot.studioDraft?.excludeStudioRecorder ?? true },
                        set: { model.send(.setDraftExcludeStudioRecorder($0)) }
                    ),
                    excludeStudioRecorderAudio: Binding(
                        get: { snapshot.studioDraft?.excludeStudioRecorderAudio ?? true },
                        set: { model.send(.setDraftExcludeStudioRecorderAudio($0)) }
                    ),
                    codecPolicy: snapshot.studioDraft?.codecPolicy ?? .automatic,
                    isLocked: snapshot.areRecordingSettingsLocked
                )
                .frame(width: 304)
                .background(.bar)
            }

            Divider()
            HStack(spacing: 16) {
                Label(
                    snapshot.capturesMicrophone ? "Microphone is included" : "Recording without microphone",
                    systemImage: "mic"
                )
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
                    Text(studioDestinationPath).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Text(studioDestinationDetail).font(.caption2).foregroundStyle(studioDestinationColor)
                }
                .frame(maxWidth: 250, alignment: .trailing)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(.bar)
        }
        .navigationTitle("Studio")
    }

    private func updateLiveScene(for route: MainRoute) async {
        guard route == .studio, snapshot.captureState == .ready else {
            await liveScene.stopCameraPreview()
            await liveScene.stopScreenPreview()
            return
        }

        if let primarySelectedDisplayID {
            await liveScene.startScreenPreview(for: primarySelectedDisplayID)
        }

        if snapshot.capturesCamera, snapshot.permissionSnapshot.camera.isGranted {
            liveScene.selectCamera(snapshot.studioDraft?.cameraDeviceID)
            liveScene.startCameraPreview()
        } else {
            await liveScene.stopCameraPreview()
        }
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
        guard !snapshot.isCaptureCommandInFlight else { return false }
        if snapshot.captureState == .recording { return true }
        return snapshot.captureState == .ready && snapshot.draftValidationIssues.isEmpty
    }

    private var recordButtonTitle: String {
        snapshot.captureState == .recording ? "Stop" : "Record"
    }

    private var statusColor: Color {
        if snapshot.showsCaptureRepair {
            return .orange
        }
        switch snapshot.captureState {
        case .recording: return .red
        case .failed: return .orange
        case .ready: return .green
        case .preparing, .stopping: return .secondary
        }
    }

    private var primarySelectedDisplayID: UInt32? {
        snapshot.availableDisplays.first(where: { snapshot.selectedDisplayIDs.contains($0.id) })?.id
    }

    private var selectedDisplayName: String {
        snapshot.availableDisplays.first(where: { $0.id == primarySelectedDisplayID })?.title ?? "Selected display"
    }

    private var studioDestinationPath: String {
        snapshot.studioDraft?.destination.url.path(percentEncoded: false) ?? "Movies/Studio Recorder"
    }

    private var studioDestinationDetail: String {
        if snapshot.studioDraft?.destination.warning == .unwritable {
            return "Choose a writable folder in Settings"
        }
        return "Recoverable project packages"
    }

    private var studioDestinationColor: Color {
        snapshot.studioDraft?.destination.warning == .unwritable ? .red : .secondary
    }

    private func toggleRecording() {
        guard snapshot.captureState == .ready else {
            model.send(.toggleRecording)
            return
        }
        Task {
            await liveScene.stopCameraPreview()
            await liveScene.stopScreenPreview()
            model.send(.toggleRecording)
        }
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
    let microphones: [AvailableMicrophone]
    @Binding var capturesSystemAudio: Bool
    let cameras: [AvailableCamera]
    @Binding var selectedCameraID: String?
    @Binding var capturesCamera: Bool
    @Binding var capturesMicrophone: Bool
    @Binding var microphoneDeviceID: String?
    let microphoneFallback: MicrophoneFallback?
    @Binding var includeCursor: Bool
    @Binding var excludeStudioRecorder: Bool
    @Binding var excludeStudioRecorderAudio: Bool
    let codecPolicy: RecordingCodecPolicy
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

                Toggle(isOn: $capturesSystemAudio) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("System audio").font(.subheadline.weight(.medium))
                        Text(capturesSystemAudio ? "Embedded once in the primary display track" : "Off for this Studio Draft")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(isLocked)
                .padding(.horizontal, 14).padding(.vertical, 11)
                .overlay(alignment: .bottom) { Divider() }
                Toggle(isOn: $capturesMicrophone) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Microphone").font(.subheadline.weight(.medium))
                        Text(capturesMicrophone ? "Embedded once in primary capture" : "Off for this Studio Draft")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(isLocked)
                .padding(.horizontal, 14).padding(.vertical, 11)
                .overlay(alignment: .bottom) { Divider() }
                if capturesMicrophone {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Microphone device", selection: $microphoneDeviceID) {
                            ForEach(microphones) { microphone in
                                Text(microphone.name).tag(Optional(microphone.id))
                            }
                        }
                        .disabled(isLocked || microphones.isEmpty)
                        if case let .savedDeviceMissing(_, fallbackID) = microphoneFallback {
                            Text(
                                fallbackID == nil
                                    ? "Saved microphone unavailable; no fallback microphone is currently available."
                                    : "Saved microphone unavailable; using the current system default."
                            )
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        } else if microphones.isEmpty {
                            Text("No microphone is currently available.")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .overlay(alignment: .bottom) { Divider() }
                }
                cameraRow

                Divider().padding(.top, 4)
                inspectorHeader("Capture")
                contractRow("Frame rate", value: "30 fps")
                contractRow("Codec", value: codecPolicy == .automatic ? "HEVC · H.264 fallback" : "H.264")
                Toggle("Include cursor", isOn: $includeCursor)
                    .disabled(isLocked)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                Toggle("Exclude Studio Recorder", isOn: $excludeStudioRecorder)
                    .disabled(isLocked)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                Toggle("Exclude app audio", isOn: $excludeStudioRecorderAudio)
                    .disabled(isLocked)
                    .padding(.horizontal, 14).padding(.vertical, 8)

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
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $capturesCamera) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Camera").font(.subheadline.weight(.medium))
                    Text(cameras.isEmpty ? "No camera available" : (capturesCamera ? "Independent recoverable raw track" : "Off for this Studio Draft"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(isLocked || cameras.isEmpty)

            if capturesCamera, !cameras.isEmpty {
                Picker("Camera", selection: $selectedCameraID) {
                    ForEach(cameras) { camera in
                        Text(camera.name).tag(Optional(camera.id))
                    }
                }
                .disabled(isLocked)
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
    let screenPreviewError: String?
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
            } else if let screenPreviewError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(.orange)
                    Text("Preview unavailable").font(.headline)
                    Text(screenPreviewError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "rectangle.on.rectangle.angled")
                        .font(.system(size: 44))
                    Text("Loading \(selectedDisplayName)…").font(.headline)
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
