import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct StudioRecorderRootView: View {
    @ObservedObject var model: StudioRecorderModel
    @ObservedObject var preferencesStore: PreferencesStore
    @ObservedObject var streamingSettings: YouTubeStreamingSettingsStore
    @StateObject private var liveScene = LiveSceneCoordinator()
    @StateObject private var streaming = YouTubeStreamingCoordinator()
    @StateObject private var streamArchive = LiveProgramArchiveCoordinator()
    @StateObject private var sceneLibrary = StudioSceneLibraryStore()
    @State private var deliveryMode = StreamDeliveryMode.record
    @State private var importedGIFSource: GIFMakerSource?
    @State private var gifImportError: String?
    @State private var recoveryOperationID: String?
    @State private var recoveryError: String?
    @State private var recoveryTrashCandidate: RecordingProjectSnapshot?
    @State private var isCapturingSnapshot = false
    @State private var lastSnapshotURL: URL?
    @State private var snapshotError: String?
    @State private var isRunningStreamPreflight = false
    @State private var streamPreflightReport: StreamPreflightReport?
    @State private var streamPreflightRevision = 0
    @State private var selectedSceneID: UUID?
    @State private var sceneSwitchError: String?
    @State private var sceneLibraryError: String?
    @State private var streamingSceneContract: StudioSceneLiveContract?

    private let streamPreflightRunner = StreamPreflightRunner()

    private let coral = Color(red: 0.90, green: 0.40, blue: 0.36)

    private var snapshot: StudioRecorderSnapshot { model.snapshot }

    private var presentedRoot: some View {
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
                    Label("Settings", systemImage: "gearshape")
                        .tag(MainRoute.settings)
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
                case .settings:
                    SettingsView(
                        model: model,
                        preferencesStore: preferencesStore,
                        streamingSettings: streamingSettings,
                        embedded: true
                    )
                case .recovery:
                    recoveryView
                }
            }
            .toolbar { toolbarContent }
        }
        .tint(coral)
        .sheet(item: $importedGIFSource) { source in
            GIFMakerView(source: source) { importedGIFSource = nil }
        }
        .alert("Video Could Not Be Opened", isPresented: gifImportErrorPresented) {
            Button("OK", role: .cancel) { gifImportError = nil }
        } message: {
            Text(gifImportError ?? "Unknown video import error")
        }
        .alert("Recovery Failed", isPresented: recoveryErrorPresented) {
            Button("OK", role: .cancel) { recoveryError = nil }
        } message: {
            Text(recoveryError ?? "The project could not be recovered.")
        }
        .alert("Snapshot Failed", isPresented: snapshotErrorPresented) {
            Button("OK", role: .cancel) { snapshotError = nil }
        } message: {
            Text(snapshotError ?? "The current stage could not be saved.")
        }
        .alert("Scene Could Not Switch", isPresented: sceneSwitchErrorPresented) {
            Button("OK", role: .cancel) { sceneSwitchError = nil }
        } message: {
            Text(sceneSwitchError ?? "This scene is not compatible with the active session.")
        }
        .alert("Scene Library Error", isPresented: sceneLibraryErrorPresented) {
            Button("OK", role: .cancel) { sceneLibraryError = nil }
        } message: {
            Text(sceneLibraryError ?? "The scene library could not be updated.")
        }
        .confirmationDialog(
            "Move this recording project to Trash?",
            isPresented: recoveryTrashConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                guard let project = recoveryTrashCandidate else { return }
                Task { await moveRecoveryProjectToTrash(project) }
            }
            Button("Cancel", role: .cancel) { recoveryTrashCandidate = nil }
        } message: {
            Text("The complete .recordingproject package will be moved to macOS Trash. No media is deleted automatically.")
        }
    }

    private var lifecycleRoot: some View {
        presentedRoot
        .task {
            await model.launch()
            await updateLiveScene(for: snapshot.route)
        }
        .onChange(of: snapshot.route) { _, route in
            if route != .studio, streaming.state.isActive {
                streaming.stop()
                Task { await liveScene.setStreamPipeline(nil, audio: nil) }
            }
            Task { await updateLiveScene(for: route) }
        }
        .onChange(of: snapshot.captureState) { _, _ in
            Task { await updateLiveScene(for: snapshot.route) }
        }
        .onChange(of: snapshot.studioDraft?.cameraDeviceID) { _, _ in
            Task { await updateLiveScene(for: snapshot.route) }
        }
        .onChange(of: snapshot.studioDraft?.presentation.cameraBackground) { _, _ in
            Task { await updateLiveScene(for: snapshot.route) }
        }
        .onChange(of: snapshot.studioDraft?.presentation) { _, presentation in
            if let presentation {
                Task { await streaming.pipeline.updatePresentation(presentation) }
            }
        }
    }

    private var preflightObservedRoot: some View {
        lifecycleRoot
        .onChange(of: snapshot.studioDraft) { _, _ in invalidateStreamPreflight() }
        .onChange(of: deliveryMode) { _, _ in invalidateStreamPreflight() }
        .onChange(of: streamingSettings.serverURL) { _, _ in invalidateStreamPreflight() }
        .onChange(of: streamingSettings.streamKey) { _, _ in invalidateStreamPreflight() }
        .onChange(of: streamingSettings.videoBitRate) { _, _ in invalidateStreamPreflight() }
        .onChange(of: streaming.state) { _, state in
            guard !state.isActive else { return }
            streamingSceneContract = nil
            Task { await liveScene.setStreamPipeline(nil, audio: nil) }
        }
        .onChange(of: streamArchive.state) { _, state in
            switch state {
            case .ready, .failed:
                Task { await model.refreshProjects() }
            case .idle, .preparing, .recording, .finalizing:
                break
            }
        }
        .onChange(of: snapshot.capturesCamera) { _, _ in
            Task { await updateLiveScene(for: snapshot.route) }
        }
    }

    var body: some View {
        preflightObservedRoot
        .onDisappear {
            streaming.stop()
            Task {
                await liveScene.setStreamPipeline(nil, audio: nil)
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
                Text(routeTitle)
                    .font(.headline)
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if snapshot.route == .projects {
                Button {
                    openVideoForGIF()
                } label: {
                    Label("Video to GIF…", systemImage: "sparkles.rectangle.stack")
                }

                Button {
                    model.send(.newRecording)
                } label: {
                    Label("New Recording", systemImage: "plus")
                }
            }
        }
    }

    private var gifImportErrorPresented: Binding<Bool> {
        Binding(
            get: { gifImportError != nil },
            set: { if !$0 { gifImportError = nil } }
        )
    }

    private var snapshotErrorPresented: Binding<Bool> {
        Binding(
            get: { snapshotError != nil },
            set: { if !$0 { snapshotError = nil } }
        )
    }

    private var sceneSwitchErrorPresented: Binding<Bool> {
        Binding(
            get: { sceneSwitchError != nil },
            set: { if !$0 { sceneSwitchError = nil } }
        )
    }

    private var sceneLibraryErrorPresented: Binding<Bool> {
        Binding(
            get: { sceneLibraryError != nil },
            set: { if !$0 { sceneLibraryError = nil } }
        )
    }

    private func openVideoForGIF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Make GIF"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            gifImportError = "The selected video is not readable."
            return
        }
        let baseName = url.deletingPathExtension().lastPathComponent
        importedGIFSource = GIFMakerSource(
            url: url,
            suggestedName: "\(baseName) clip.gif",
            initialStartTime: 0
        )
    }

    private var routeTitle: String {
        switch snapshot.route {
        case .projects: "Projects"
        case .settings: "Settings"
        case .recovery: "Recovery"
        case .studio: "Studio"
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
                            Text("Retained source media stays recoverable. Layout and cuts remain non-destructive.")
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
            if let warning = snapshot.finalizationWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Color.orange.opacity(0.08))
            }
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(snapshot.studioDraft?.presentation.resolvedName ?? "Scene 1")
                            .font(.headline)
                        Spacer()
                        Text("\(canvasWidth) × \(canvasHeight)  ·  30 fps")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("Live scene")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                    SceneSwitcherBar(
                        scenes: sceneLibrary.scenes,
                        selectedSceneID: selectedSceneID,
                        isLive: isDeliveryActive,
                        canManage: !isDeliveryActive,
                        incompatibility: { liveSceneContract?.incompatibility(for: $0.presentation) },
                        onSelect: applyScene,
                        onSave: saveCurrentScene,
                        onCreate: createScene,
                        onDelete: deleteSelectedScene
                    )
                    LiveProgramPreview(
                        screenImage: liveScene.screenImage,
                        cameraSession: liveScene.cameraSession,
                        cameraImage: liveScene.cameraImage,
                        selectedDisplayName: selectedDisplayName,
                        selectedDisplayID: primarySelectedDisplayID,
                        screenPreviewError: liveScene.screenPreviewError,
                        isRecording: snapshot.captureState == .recording,
                        presentation: presentationBinding,
                        isLocked: snapshot.areRecordingSettingsLocked
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
                    retentionPolicy: Binding(
                        get: { snapshot.studioDraft?.retentionPolicy ?? .editableTracks },
                        set: { model.send(.setDraftRetentionPolicy($0)) }
                    ),
                    presentation: presentationBinding,
                    isLocked: snapshot.areRecordingSettingsLocked || streaming.state.isActive
                )
                .frame(width: 304)
                .background(.bar)
            }

            Divider()
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Picker("Output", selection: $deliveryMode) {
                        ForEach(StreamDeliveryMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 286)
                    .disabled(snapshot.captureState == .recording || streaming.state.isActive)
                    Label(streaming.state.label, systemImage: streaming.state == .live ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(streaming.state == .live ? .red : .secondary)
                    if snapshot.captureState == .recording,
                       streaming.state.isReconnecting || streaming.state.hasFailed {
                        Label("Local recording continues", systemImage: "record.circle")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                    if deliveryMode == .stream || streamArchive.state.isActive {
                        Label(streamArchive.state.label, systemImage: "externaldrive.fill")
                            .font(.caption2)
                            .foregroundStyle(streamArchiveColor)
                    }
                    if let health = streaming.health, streaming.state.isActive {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(streamHealthOutputSummary(health))
                            Text(streamHealthPerformanceSummary(health))
                                .foregroundStyle(streamHealthColor(health))
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    if deliveryMode.includesStreaming, streamConfiguration == nil {
                        Text("Add the YouTube RTMPS key in Settings → Streaming")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if deliveryMode.includesStreaming, !streaming.state.isActive {
                        StreamPreflightSummaryView(
                            report: streamPreflightReport,
                            isRunning: isRunningStreamPreflight,
                            onRun: { Task { await runStreamPreflight() } }
                        )
                        .frame(width: 286, alignment: .leading)
                    }
                }
                Spacer()
                Button(action: captureProgramSnapshot) {
                    if isCapturingSnapshot {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Snapshot", systemImage: "camera.viewfinder")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(
                    isCapturingSnapshot
                        || liveScene.screenImage == nil
                        || snapshotNeedsCameraFrame
                )
                Button(action: toggleDelivery) {
                    Label(deliveryButtonTitle, systemImage: isDeliveryActive ? "stop.fill" : "record.circle.fill")
                        .frame(minWidth: 122)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(isDeliveryActive ? .red : coral)
                .disabled(!canToggleDelivery)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(studioDestinationPath).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if let lastSnapshotURL {
                        HStack(spacing: 8) {
                            Label("Snapshot saved", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Button("Copy") { copySnapshot(lastSnapshotURL) }
                            Button("Reveal") {
                                NSWorkspace.shared.activateFileViewerSelecting([lastSnapshotURL])
                            }
                            ShareLink(item: lastSnapshotURL) {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .accessibilityLabel("Share snapshot")
                        }
                        .buttonStyle(.plain)
                        .font(.caption2)
                    } else {
                        Text(studioDestinationDetail).font(.caption2).foregroundStyle(studioDestinationColor)
                    }
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
        guard route == .studio else {
            await liveScene.stopScreenPreview()
            if !LiveScenePolicy.shouldPreserveCameraSession(captureState: snapshot.captureState) {
                await liveScene.stopCameraPreview()
            }
            return
        }
        guard LiveScenePolicy.shouldRun(route: route, captureState: snapshot.captureState) else {
            await liveScene.stopCameraPreview()
            await liveScene.stopScreenPreview()
            return
        }

        if let primarySelectedDisplayID {
            await liveScene.startScreenPreview(for: primarySelectedDisplayID)
        }
        liveScene.setCameraBackground(
            snapshot.studioDraft?.presentation.resolvedCameraBackground ?? .off
        )

        if LiveScenePolicy.shouldRunDraftCamera(route: route, captureState: snapshot.captureState),
           snapshot.capturesCamera,
           snapshot.permissionSnapshot.camera.isGranted {
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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Recovery Review")
                                .font(.title2.weight(.semibold))
                            Text("Studio Recorder found projects that did not close cleanly. Recover keeps only verified playable tracks; unavailable files and the original diagnostics are never silently discarded.")
                                .foregroundStyle(.secondary)
                        }

                        ForEach(snapshot.interruptedProjects) { project in
                            recoveryCard(project)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 900, alignment: .leading)
                }
            }
        }
        .navigationTitle("Recovery")
    }

    private func recoveryCard(_ project: RecordingProjectSnapshot) -> some View {
        let playableCount = recoveryPlayableCount(project)
        let unavailableCount = max(project.recoveryReport.tracks.count - playableCount, 0)
        let isWorking = recoveryOperationID == project.id

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: project.lifecycle == .unreadable ? "exclamationmark.octagon.fill" : "lifepreserver.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.presentation?.resolvedName ?? "Interrupted Recording")
                        .font(.headline)
                    Text(project.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(playableCount) playable · \(unavailableCount) unavailable")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(playableCount > 0 ? Color.primary : Color.orange)
                }
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
            }

            if project.recoveryReport.tracks.isEmpty {
                Text("The package metadata is unreadable. Reveal it for manual inspection or move the complete package to Trash.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                VStack(spacing: 0) {
                    ForEach(project.recoveryReport.tracks) { track in
                        HStack(spacing: 10) {
                            Image(systemName: recoveryTrackIcon(track.descriptor.kind))
                                .frame(width: 18)
                                .foregroundStyle(recoveryTrackIsPlayable(track) ? Color.green : Color.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(recoveryTrackTitle(track.descriptor))
                                    .font(.subheadline.weight(.medium))
                                Text(recoveryTrackDetail(track))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: recoveryTrackIsPlayable(track) ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(recoveryTrackIsPlayable(track) ? Color.green : Color.orange)
                        }
                        .padding(.vertical, 9)
                        if track.id != project.recoveryReport.tracks.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 12)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            }

            if let diagnostic = project.recoveryReport.diagnostics.first {
                Label(diagnostic, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: 10) {
                Button("Recover \(playableCount) Track\(playableCount == 1 ? "" : "s")", systemImage: "checkmark.shield") {
                    Task { await recoverProject(project) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(playableCount == 0 || project.lifecycle != .needsRecovery || recoveryOperationID != nil)

                Button("Review Media", systemImage: "play.rectangle") {
                    model.send(.openProject(project.id))
                }
                .disabled(playableCount == 0 || recoveryOperationID != nil)

                Button("Reveal", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([project.rootURL])
                }

                Spacer()

                Button("Move to Trash…", systemImage: "trash", role: .destructive) {
                    recoveryTrashCandidate = project
                }
                .disabled(recoveryOperationID != nil)
            }
            .buttonStyle(.bordered)
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.primary.opacity(0.10), lineWidth: 1)
        }
    }

    private func recoverProject(_ project: RecordingProjectSnapshot) async {
        recoveryOperationID = project.id
        defer { recoveryOperationID = nil }
        do {
            try await model.recoverProject(project.id)
            model.send(.openProject(project.id))
        } catch {
            recoveryError = error.localizedDescription
        }
    }

    private func moveRecoveryProjectToTrash(_ project: RecordingProjectSnapshot) async {
        recoveryTrashCandidate = nil
        recoveryOperationID = project.id
        defer { recoveryOperationID = nil }
        do {
            try await model.moveRecoveryProjectToTrash(project.id)
        } catch {
            recoveryError = error.localizedDescription
        }
    }

    private func recoveryPlayableCount(_ project: RecordingProjectSnapshot) -> Int {
        project.recoveryReport.tracks.filter(recoveryTrackIsPlayable).count
    }

    private func recoveryTrackIsPlayable(_ track: RecordingTrackRecoverySnapshot) -> Bool {
        track.state == .finalized || track.state == .partialReadable
    }

    private func recoveryTrackTitle(_ track: RecordingTrackDescriptor) -> String {
        switch track.kind {
        case .screen: track.displayID.map { "Display \($0)" } ?? "Screen"
        case .camera: "Camera"
        case .program: "Program movie"
        }
    }

    private func recoveryTrackIcon(_ kind: RecordingTrackKind) -> String {
        switch kind {
        case .screen: "display"
        case .camera: "video"
        case .program: "rectangle.inset.filled.and.person.filled"
        }
    }

    private func recoveryTrackDetail(_ track: RecordingTrackRecoverySnapshot) -> String {
        let state: String = switch track.state {
        case .finalized: "Finalized"
        case .partialReadable: "Playable partial recording"
        case .missing: "Missing"
        case .unreadable: "Unreadable"
        case .unknownV1: "Legacy status unknown"
        }
        let size = track.fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return [state, size].compactMap { $0 }.joined(separator: " · ")
    }

    private var recoveryErrorPresented: Binding<Bool> {
        Binding(get: { recoveryError != nil }, set: { if !$0 { recoveryError = nil } })
    }

    private var recoveryTrashConfirmationPresented: Binding<Bool> {
        Binding(
            get: { recoveryTrashCandidate != nil },
            set: { if !$0 { recoveryTrashCandidate = nil } }
        )
    }

    private var canToggleDelivery: Bool {
        guard !snapshot.isCaptureCommandInFlight,
              !isRunningStreamPreflight else { return false }
        if isDeliveryActive { return true }
        guard snapshot.captureState == .ready,
              snapshot.draftValidationIssues.isEmpty else { return false }
        return true
    }

    private var isDeliveryActive: Bool {
        snapshot.captureState == .recording || streaming.state.isActive
    }

    private var streamArchiveColor: Color {
        if case .failed = streamArchive.state { return .orange }
        if case .ready = streamArchive.state { return .green }
        return .secondary
    }

    private var deliveryButtonTitle: String {
        if isRunningStreamPreflight, !isDeliveryActive { return "Checking…" }
        return isDeliveryActive ? "Stop" : deliveryMode.label
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

    private var canvasWidth: Int { snapshot.studioDraft?.presentation.canvas.width ?? 1_920 }
    private var canvasHeight: Int { snapshot.studioDraft?.presentation.canvas.height ?? 1_080 }

    private var presentationBinding: Binding<CapturePresentationSnapshot> {
        Binding(
            get: { snapshot.studioDraft?.presentation ?? .default },
            set: { model.send(.setDraftPresentation($0)) }
        )
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

    private var streamConfiguration: YouTubeStreamConfiguration? {
        streamingSettings.configuration(
            canvasSize: CGSize(width: canvasWidth, height: canvasHeight),
            frameRate: snapshot.studioDraft?.frameRate ?? 30
        )
    }

    private var streamPreflightRequest: StreamPreflightRequest? {
        guard let draft = snapshot.studioDraft else { return nil }
        return StreamPreflightRequest(
            deliveryMode: deliveryMode,
            serverURL: streamingSettings.serverURL,
            hasStreamKey: !streamingSettings.streamKey
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty,
            canvasSize: draft.presentation.canvas.pixelSize,
            frameRate: draft.frameRate,
            videoBitRate: streamingSettings.videoBitRate,
            destinationURL: draft.destination.url,
            capturesSystemAudio: draft.capturesSystemAudio,
            capturesMicrophone: draft.capturesMicrophone,
            capturesCamera: draft.capturesCamera,
            cameraBackground: draft.presentation.resolvedCameraBackground,
            selectedDisplaySizes: snapshot.availableDisplays
                .filter { draft.selectedDisplayIDs.contains($0.id) }
                .map(\.pixelSize),
            revision: streamPreflightRevision
        )
    }

    private func streamHealthOutputSummary(_ health: LiveStreamHealthSnapshot) -> String {
        let width = Int(health.canvasSize.width)
        let height = Int(health.canvasSize.height)
        let bitrate = Double(health.videoBitRate) / 1_000_000
        return "\(width)×\(height) · \(String(format: "%.0f", bitrate)) Mbps"
    }

    private func streamHealthPerformanceSummary(_ health: LiveStreamHealthSnapshot) -> String {
        let measuredFPS = health.measuredFrameRate
        let fps = measuredFPS > 0 ? String(format: "%.1f fps", measuredFPS) : "warming up"
        return "\(fps) · \(String(format: "%.1f", health.averageRenderMilliseconds)) ms render · \(health.droppedVideoFrames) dropped"
    }

    private func streamHealthColor(_ health: LiveStreamHealthSnapshot) -> Color {
        if health.droppedVideoFrames > 0 { return .orange }
        if health.measuredFrameRate > 0,
           health.measuredFrameRate < Double(health.targetFrameRate) * 0.80 { return .orange }
        return .secondary
    }

    private func toggleDelivery() {
        if isDeliveryActive {
            if snapshot.captureState == .recording {
                model.send(.toggleRecording)
            }
            if streaming.state.isActive {
                streaming.stop()
                Task { await liveScene.setStreamPipeline(nil, audio: nil) }
            }
            return
        }
        Task { await startDelivery() }
    }

    @MainActor
    private func startDelivery() async {
        guard snapshot.route == .studio,
              let draft = snapshot.studioDraft else { return }
        if deliveryMode.includesStreaming {
            guard let report = await runStreamPreflight(),
                  report.canStart,
                  snapshot.route == .studio,
                  let streamConfiguration else { return }
            let audio = LiveStreamAudioConfiguration(
                capturesSystemAudio: draft.capturesSystemAudio,
                capturesMicrophone: draft.capturesMicrophone,
                microphoneDeviceID: draft.microphoneDeviceID,
                excludesStudioRecorderAudio: draft.excludeStudioRecorderAudio
            )
            let localArchive: LiveProgramArchiveSession?
            if deliveryMode == .stream {
                guard let request = model.makeCaptureRequest(retentionPolicy: .programOnly),
                      let archive = streamArchive.start(
                        request: request,
                        streamConfiguration: streamConfiguration,
                        audioConfiguration: audio
                      ) else { return }
                localArchive = archive
            } else {
                localArchive = nil
            }
            await liveScene.setStreamPipeline(streaming.pipeline, audio: audio)
            streamingSceneContract = StudioSceneLiveContract(
                initialPresentation: draft.presentation,
                capturesCamera: draft.capturesCamera,
                recordsCursorTelemetry: draft.includeCursor || draft.presentation.framing.mode == .followCursor
            )
            streaming.start(
                configuration: streamConfiguration,
                presentation: draft.presentation,
                includesCursor: draft.includeCursor,
                audioConfiguration: audio,
                localArchive: localArchive
            )
        }
        if deliveryMode.includesRecording {
            model.useCameraPreviewSessionForRecording(liveScene.cameraSession)
            model.send(.toggleRecording)
        }
    }

    @MainActor
    @discardableResult
    private func runStreamPreflight() async -> StreamPreflightReport? {
        guard !isRunningStreamPreflight,
              let request = streamPreflightRequest else { return nil }
        isRunningStreamPreflight = true
        streamPreflightReport = nil
        let report = await streamPreflightRunner.run(request: request)
        guard streamPreflightRequest == request else {
            isRunningStreamPreflight = false
            return nil
        }
        streamPreflightReport = report
        isRunningStreamPreflight = false
        return report
    }

    private func invalidateStreamPreflight() {
        streamPreflightRevision &+= 1
        streamPreflightReport = nil
    }

    private var liveSceneContract: StudioSceneLiveContract? {
        if let request = snapshot.activeCaptureRequest {
            return StudioSceneLiveContract(
                initialPresentation: request.presentation,
                capturesCamera: request.camera != nil,
                recordsCursorTelemetry: request.includesCursor
                    || request.presentation.framing.mode == .followCursor
            )
        }
        return streamingSceneContract
    }

    private func applyScene(_ scene: StudioScenePreset) {
        if let incompatibility = liveSceneContract?.incompatibility(for: scene.presentation) {
            sceneSwitchError = incompatibility.message
            return
        }
        guard model.send(.setDraftPresentation(scene.presentation)) != .ignored else {
            sceneSwitchError = "Studio Recorder could not apply this scene to the current session."
            return
        }
        selectedSceneID = scene.id
    }

    private func saveCurrentScene() {
        guard let presentation = snapshot.studioDraft?.presentation else { return }
        let scene = selectedSceneID.flatMap(sceneLibrary.scene(id:)).map {
            StudioScenePreset(id: $0.id, presentation: presentation)
        } ?? StudioScenePreset(presentation: presentation)
        do {
            try sceneLibrary.save(scene)
            selectedSceneID = scene.id
        } catch {
            sceneLibraryError = error.localizedDescription
        }
    }

    private func createScene() {
        guard var presentation = snapshot.studioDraft?.presentation else { return }
        let usedNames = Set(sceneLibrary.scenes.map(\.name))
        var index = sceneLibrary.scenes.count + 1
        while usedNames.contains("Scene \(index)") { index += 1 }
        presentation.name = "Scene \(index)"
        let scene = StudioScenePreset(presentation: presentation)
        do {
            try sceneLibrary.save(scene)
            selectedSceneID = scene.id
            model.send(.setDraftPresentation(scene.presentation))
        } catch {
            sceneLibraryError = error.localizedDescription
        }
    }

    private func deleteSelectedScene() {
        guard let selectedSceneID else { return }
        do {
            try sceneLibrary.remove(selectedSceneID)
            self.selectedSceneID = nil
        } catch {
            sceneLibraryError = error.localizedDescription
        }
    }

    private func captureProgramSnapshot() {
        guard !isCapturingSnapshot,
              let draft = snapshot.studioDraft else { return }
        isCapturingSnapshot = true
        Task { @MainActor in
            defer { isCapturingSnapshot = false }
            do {
                let destinationURL = try nextSnapshotURL(
                    in: draft.destination.url,
                    sceneName: draft.presentation.resolvedName
                )
                try await liveScene.saveProgramSnapshot(
                    presentation: draft.presentation,
                    capturesCamera: draft.capturesCamera,
                    includesCursor: draft.includeCursor,
                    excludesStudioRecorder: draft.excludeStudioRecorder,
                    to: destinationURL
                )
                lastSnapshotURL = destinationURL
            } catch {
                snapshotError = error.localizedDescription
            }
        }
    }

    private var snapshotNeedsCameraFrame: Bool {
        guard let draft = snapshot.studioDraft else { return false }
        return draft.capturesCamera
            && draft.presentation.camera.isVisible
            && !liveScene.isCameraFrameReady
    }

    private func nextSnapshotURL(in destination: URL, sceneName: String) throws -> URL {
        let directory = destination.appending(path: "Screenshots", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let safeSceneName = sceneName.components(separatedBy: allowed.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let baseName = "\(safeSceneName.isEmpty ? "Scene" : safeSceneName) Snapshot \(timestamp)"
        var candidate = directory.appending(path: "\(baseName).png")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: "\(baseName) \(suffix).png")
            suffix += 1
        }
        return candidate
    }

    private func copySnapshot(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            snapshotError = "The saved snapshot could not be copied."
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([image]) else {
            snapshotError = "The saved snapshot could not be copied."
            return
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
                Text(project.presentation?.resolvedName ?? "Scene 1")
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
        case .recovered: "Recovered"
        case .needsRecovery: "Needs recovery"
        case .unreadable: "Unreadable"
        }
    }

    private var statusColor: Color {
        switch project.lifecycle {
        case .finalized: .green
        case .recovered: .blue
        case .needsRecovery, .unreadable: .orange
        case .recording, .finalizing: .secondary
        }
    }

    private var statusIcon: String {
        switch project.lifecycle {
        case .finalized: "display.2"
        case .recovered: "checkmark.shield"
        case .needsRecovery, .unreadable: "exclamationmark.triangle"
        case .recording: "record.circle"
        case .finalizing: "clock"
        }
    }
}

private struct StudioInspector: View {
    private enum SourceSettings: String, Identifiable {
        case screens
        case camera
        case microphone

        var id: String { rawValue }
    }

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
    @Binding var retentionPolicy: MediaRetentionPolicy
    @Binding var presentation: CapturePresentationSnapshot
    let isLocked: Bool
    @State private var activeSourceSettings: SourceSettings?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                inspectorHeader("Scene")
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Scene name", text: sceneNameBinding)
                        .textFieldStyle(.roundedBorder)

                    Picker("Output", selection: canvasPresetBinding) {
                        ForEach(CaptureCanvasPreset.allCases) { preset in
                            Text(preset.label).tag(Optional(preset))
                        }
                        Divider()
                        Text("Custom").tag(Optional<CaptureCanvasPreset>.none)
                    }

                    if presentation.canvas.preset == nil {
                        HStack(spacing: 8) {
                            TextField("Width", value: canvasWidthBinding, format: .number)
                            Text("×").foregroundStyle(.secondary)
                            TextField("Height", value: canvasHeightBinding, format: .number)
                        }
                        .textFieldStyle(.roundedBorder)
                    }

                    Picker("Screen", selection: framingModeBinding) {
                        ForEach(ScreenFramingMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }

                    if presentation.framing.mode != .fullDisplay {
                        labeledSlider(
                            "Zoom",
                            value: framingScaleBinding,
                            range: 0.15...1,
                            valueText: String(format: "%.1f×", 1 / presentation.framing.scale)
                        )
                        labeledSlider("Horizontal", value: framingCenterXBinding, range: 0...1)
                        labeledSlider("Vertical", value: framingCenterYBinding, range: 0...1)
                        if presentation.framing.mode == .followCursor {
                            Text("Follow Cursor records scene motion while the full raw display remains recoverable.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("Canvas and source placement are saved with the take; screen and camera raw tracks remain independent.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .disabled(isLocked)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

                Divider()
                inspectorHeader("Sources")
                sourceSettingsButton(
                    .screens,
                    title: "Screens",
                    detail: "\(selectedDisplayIDs.count) selected",
                    icon: "display.2"
                )
                sourceSettingsButton(
                    .camera,
                    title: "Camera",
                    detail: capturesCamera ? selectedCameraName : "Off",
                    icon: "video"
                )
                sourceSettingsButton(
                    .microphone,
                    title: "Microphone & audio",
                    detail: audioSourceSummary,
                    icon: "waveform"
                )

                Divider().padding(.top, 4)
                inspectorHeader("Capture")
                contractRow("Frame rate", value: "30 fps")
                contractRow("Codec", value: codecPolicy == .automatic ? "HEVC · H.264 fallback" : "H.264")
                Toggle("Include cursor", isOn: $includeCursor)
                    .disabled(isLocked)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                if includeCursor {
                    VStack(alignment: .leading, spacing: 8) {
                        labeledSlider(
                            "Export cursor size",
                            value: cursorScaleBinding,
                            range: 1...4,
                            valueText: String(format: "%.1f×", presentation.cursor.scale)
                        )
                        Toggle("Highlight clicks", isOn: cursorClickBinding)
                        Text("Cursor size and click rings render into playback, program recordings, exports, and streams. The editable raw screen track stays clean.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(isLocked)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
                Toggle("Exclude Studio Recorder", isOn: $excludeStudioRecorder)
                    .disabled(isLocked)
                    .padding(.horizontal, 14).padding(.vertical, 8)

                Divider().padding(.top, 4)
                inspectorHeader("Resilience")
                Picker("After recording", selection: $retentionPolicy) {
                    ForEach(MediaRetentionPolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
                .disabled(isLocked)
                .padding(.horizontal, 14)
                Text(retentionPolicy == .editableTracks
                    ? "Keeps screen and camera tracks independently editable."
                    : "Finishes one composed MOV, verifies it, then removes independent raw tracks.")
                    .font(.caption2)
                    .foregroundStyle(retentionPolicy == .programOnly ? .orange : .secondary)
                    .padding(.horizontal, 14)
                Text("Raw tracks and an append-only journal are written into one recoverable project package.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.bottom, 18)
            }
        }
    }

    private func sourceSettingsButton(
        _ settings: SourceSettings,
        title: String,
        detail: String,
        icon: String
    ) -> some View {
        Button {
            activeSourceSettings = settings
        } label: {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.medium))
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(activeSourceSettings == settings ? Color.accentColor.opacity(0.10) : Color.clear)
        .overlay(alignment: .bottom) { Divider() }
        .popover(
            isPresented: Binding(
                get: { activeSourceSettings == settings },
                set: { if !$0 { activeSourceSettings = nil } }
            ),
            arrowEdge: .trailing
        ) {
            sourceSettingsPanel(settings)
                .frame(width: 330)
                .padding(16)
        }
    }

    @ViewBuilder
    private func sourceSettingsPanel(_ settings: SourceSettings) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(settingsTitle(settings)).font(.headline)
                Spacer()
                if isLocked {
                    Label("Locked", systemImage: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            switch settings {
            case .screens:
                ForEach(displays) { display in
                    Toggle(isOn: binding(for: display.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(display.title).font(.subheadline.weight(.medium))
                            Text("\(Int(display.pixelSize.width)) × \(Int(display.pixelSize.height))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 44)
                }
                Divider()
                sourceLayoutControls(placement: screenPlacementBinding)

            case .camera:
                Toggle("Use camera", isOn: $capturesCamera)
                    .disabled(cameras.isEmpty)
                if capturesCamera, !cameras.isEmpty {
                    Picker("Device", selection: $selectedCameraID) {
                        ForEach(cameras) { camera in
                            Text(camera.name).tag(Optional(camera.id))
                        }
                    }
                    Divider()
                    sourceLayoutControls(placement: cameraPlacementBinding, includesMirror: true)
                } else if cameras.isEmpty {
                    Text("No camera is currently available.")
                        .font(.caption).foregroundStyle(.orange)
                }

            case .microphone:
                Toggle("Use microphone", isOn: $capturesMicrophone)
                if capturesMicrophone {
                    Picker("Device", selection: $microphoneDeviceID) {
                        ForEach(microphones) { microphone in
                            Text(microphone.name).tag(Optional(microphone.id))
                        }
                    }
                    .disabled(microphones.isEmpty)
                    microphoneAvailabilityMessage
                }
                Divider()
                Toggle("Capture system audio", isOn: $capturesSystemAudio)
                Toggle("Exclude Studio Recorder audio", isOn: $excludeStudioRecorderAudio)
            }
        }
        .disabled(isLocked)
    }

    @ViewBuilder
    private var microphoneAvailabilityMessage: some View {
        if case let .savedDeviceMissing(_, fallbackID) = microphoneFallback {
            Text(fallbackID == nil
                ? "Saved microphone unavailable; no fallback is available."
                : "Saved microphone unavailable; using the system default.")
                .font(.caption2).foregroundStyle(.orange)
        } else if microphones.isEmpty {
            Text("No microphone is currently available.")
                .font(.caption2).foregroundStyle(.orange)
        }
    }

    private var selectedCameraName: String {
        cameras.first { $0.id == selectedCameraID }?.name ?? "Camera enabled"
    }

    private var audioSourceSummary: String {
        switch (capturesMicrophone, capturesSystemAudio) {
        case (true, true): "Microphone + system audio"
        case (true, false): "Microphone"
        case (false, true): "System audio"
        case (false, false): "Off"
        }
    }

    private func settingsTitle(_ settings: SourceSettings) -> String {
        switch settings {
        case .screens: "Screen sources & layout"
        case .camera: "Camera source & layout"
        case .microphone: "Microphone & audio"
        }
    }

    private func inspectorHeader(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 14)
    }

    @ViewBuilder
    private func sourceLayoutControls(
        placement: Binding<SourcePlacementSnapshot>,
        includesMirror: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if includesMirror {
                Picker("Camera frame", selection: cameraAspectPresetBinding) {
                    ForEach(SourceAspectPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                Picker("Background", selection: cameraBackgroundModeBinding) {
                    ForEach(CameraBackgroundMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                if presentation.resolvedCameraBackground.mode == .person {
                    Text("Person is private and local, but it keeps the person—not a separate microphone or stand.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if presentation.resolvedCameraBackground.mode == .greenScreen {
                    Picker("Key color", selection: chromaKeyColorBinding) {
                        ForEach(ChromaKeyColor.allCases) { color in
                            Text(color.label).tag(color)
                        }
                    }
                    labeledSlider("Tolerance", value: chromaToleranceBinding, range: 0.02...0.8)
                    labeledSlider("Edge softness", value: chromaSoftnessBinding, range: 0.01...0.5)
                    labeledSlider("Spill suppression", value: chromaSpillBinding, range: 0...1)
                    Text("Green Screen preserves foreground objects such as a microphone when they are not the key color.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Picker("Shape", selection: shapeBinding(for: placement)) {
                ForEach(SourceShape.allCases) { shape in
                    Text(shape.label).tag(shape)
                }
            }
            if placement.wrappedValue.shape == .roundedRectangle {
                labeledSlider(
                    "Corner radius",
                    value: cornerRadiusBinding(for: placement),
                    range: 0.02...0.5,
                    valueText: String(format: "%.0f%%", placement.wrappedValue.effectiveCornerRadius * 100)
                )
            }
            labeledSlider("Width", value: placement.width, range: 0.08...1)
            labeledSlider("Height", value: placement.height, range: 0.08...1)
            labeledSlider("Horizontal", value: placement.centerX, range: 0...1)
            labeledSlider("Vertical", value: placement.centerY, range: 0...1)
            if includesMirror {
                Toggle("Mirror camera", isOn: placement.isMirrored)
            }
        }
        .padding(.top, 8)
    }

    private func labeledSlider(
        _ label: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        valueText: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let valueText {
                    Text(valueText).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Slider(value: value, in: range)
        }
    }

    private func shapeBinding(
        for placement: Binding<SourcePlacementSnapshot>
    ) -> Binding<SourceShape> {
        Binding(
            get: { placement.wrappedValue.shape },
            set: { shape in
                var value = placement.wrappedValue
                value.shape = shape
                if shape == .roundedRectangle, value.cornerRadius == 0 {
                    value.cornerRadius = 0.12
                }
                placement.wrappedValue = value
            }
        )
    }

    private func cornerRadiusBinding(
        for placement: Binding<SourcePlacementSnapshot>
    ) -> Binding<CGFloat> {
        Binding(
            get: { placement.wrappedValue.effectiveCornerRadius },
            set: { radius in
                var value = placement.wrappedValue
                value.cornerRadius = radius
                placement.wrappedValue = value
            }
        )
    }

    private var canvasPresetBinding: Binding<CaptureCanvasPreset?> {
        Binding(
            get: { presentation.canvas.preset },
            set: { preset in
                if let preset {
                    presentation.canvas = CaptureCanvasSnapshot(preset: preset)
                } else {
                    presentation.canvas = CaptureCanvasSnapshot(
                        width: presentation.canvas.width,
                        height: presentation.canvas.height
                    )
                }
            }
        )
    }

    private var sceneNameBinding: Binding<String> {
        Binding(
            get: { presentation.name ?? presentation.resolvedName },
            set: { presentation.name = String($0.prefix(80)) }
        )
    }

    private var canvasWidthBinding: Binding<Int> {
        Binding(
            get: { presentation.canvas.width },
            set: { presentation.canvas = CaptureCanvasSnapshot(width: $0, height: presentation.canvas.height) }
        )
    }

    private var canvasHeightBinding: Binding<Int> {
        Binding(
            get: { presentation.canvas.height },
            set: { presentation.canvas = CaptureCanvasSnapshot(width: presentation.canvas.width, height: $0) }
        )
    }

    private var framingModeBinding: Binding<ScreenFramingMode> {
        Binding(
            get: { presentation.framing.mode },
            set: { mode in
                presentation.framing.mode = mode
                if mode == .followCursor, presentation.framing.scale >= 0.99 {
                    presentation.framing.scale = 0.55
                }
            }
        )
    }

    private var framingScaleBinding: Binding<CGFloat> {
        Binding(get: { presentation.framing.scale }, set: { presentation.framing.scale = $0 })
    }

    private var framingCenterXBinding: Binding<CGFloat> {
        Binding(get: { presentation.framing.centerX }, set: { presentation.framing.centerX = $0 })
    }

    private var framingCenterYBinding: Binding<CGFloat> {
        Binding(get: { presentation.framing.centerY }, set: { presentation.framing.centerY = $0 })
    }

    private var screenPlacementBinding: Binding<SourcePlacementSnapshot> {
        Binding(get: { presentation.screen }, set: { presentation.screen = $0 })
    }

    private var cameraPlacementBinding: Binding<SourcePlacementSnapshot> {
        Binding(get: { presentation.camera }, set: { presentation.camera = $0 })
    }

    private var cameraAspectPresetBinding: Binding<SourceAspectPreset> {
        Binding(
            get: { presentation.camera.matchingAspectPreset(on: presentation.canvas) },
            set: { presentation.camera = presentation.camera.applying(aspectPreset: $0, on: presentation.canvas) }
        )
    }

    private var cameraBackgroundModeBinding: Binding<CameraBackgroundMode> {
        Binding(
            get: { presentation.resolvedCameraBackground.mode },
            set: { mode in
                var background = presentation.resolvedCameraBackground
                background.mode = mode
                presentation.cameraBackground = background
            }
        )
    }

    private var chromaKeyColorBinding: Binding<ChromaKeyColor> {
        Binding(
            get: { presentation.resolvedCameraBackground.keyColor },
            set: { value in updateCameraBackground { $0.keyColor = value } }
        )
    }

    private var chromaToleranceBinding: Binding<CGFloat> {
        Binding(
            get: { presentation.resolvedCameraBackground.tolerance },
            set: { value in updateCameraBackground { $0.tolerance = value } }
        )
    }

    private var chromaSoftnessBinding: Binding<CGFloat> {
        Binding(
            get: { presentation.resolvedCameraBackground.softness },
            set: { value in updateCameraBackground { $0.softness = value } }
        )
    }

    private var chromaSpillBinding: Binding<CGFloat> {
        Binding(
            get: { presentation.resolvedCameraBackground.spillSuppression },
            set: { value in updateCameraBackground { $0.spillSuppression = value } }
        )
    }

    private func updateCameraBackground(_ update: (inout CameraBackgroundSnapshot) -> Void) {
        var background = presentation.resolvedCameraBackground
        update(&background)
        presentation.cameraBackground = background.validated()
    }

    private var cursorScaleBinding: Binding<CGFloat> {
        Binding(get: { presentation.cursor.scale }, set: { presentation.cursor.scale = $0 })
    }

    private var cursorClickBinding: Binding<Bool> {
        Binding(get: { presentation.cursor.highlightsClicks }, set: { presentation.cursor.highlightsClicks = $0 })
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
    let cameraImage: NSImage?
    let selectedDisplayName: String
    let selectedDisplayID: UInt32?
    let screenPreviewError: String?
    let isRecording: Bool
    @Binding var presentation: CapturePresentationSnapshot
    let isLocked: Bool

    @GestureState private var screenDrag: CGSize = .zero
    @GestureState private var cameraDrag: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.78))
                if let screenImage {
                    trackedScreenPreview(image: screenImage)
                        .frame(
                            width: proxy.size.width * presentation.screen.width,
                            height: proxy.size.height * presentation.screen.height
                        )
                        .clipShape(sourceShape(
                            for: presentation.screen,
                            size: CGSize(
                                width: proxy.size.width * presentation.screen.width,
                                height: proxy.size.height * presentation.screen.height
                            )
                        ))
                        .position(
                            x: proxy.size.width * presentation.screen.centerX + screenDrag.width,
                            y: proxy.size.height * presentation.screen.centerY + screenDrag.height
                        )
                        .contentShape(Rectangle())
                        .gesture(screenDragGesture(in: proxy.size))
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "rectangle.on.rectangle.angled")
                            .font(.system(size: 44))
                        Text("Loading \(selectedDisplayName)…").font(.headline)
                        Text("The selected screen will appear before recording starts.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if let cameraSession, presentation.camera.isVisible {
                    cameraPreview(session: cameraSession)
                        .scaleEffect(x: presentation.camera.isMirrored ? -1 : 1, y: 1)
                        .frame(
                            width: proxy.size.width * presentation.camera.width,
                            height: proxy.size.height * presentation.camera.height
                        )
                        .clipShape(sourceShape(
                            for: presentation.camera,
                            size: CGSize(
                                width: proxy.size.width * presentation.camera.width,
                                height: proxy.size.height * presentation.camera.height
                            )
                        ))
                        .position(
                            x: proxy.size.width * presentation.camera.centerX + cameraDrag.width,
                            y: proxy.size.height * presentation.camera.centerY + cameraDrag.height
                        )
                        .contentShape(Rectangle())
                        .gesture(cameraDragGesture(in: proxy.size))
                        .accessibilityLabel("Selected camera preview")
                }

                HStack {
                    Text(presentation.framing.mode.label)
                    Spacer()
                    Text("\(presentation.canvas.width) × \(presentation.canvas.height)")
                }
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(.white.opacity(0.86))
                .padding(10)

                if isRecording {
                    Label("REC", systemImage: "record.circle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.red)
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
        }
        .aspectRatio(presentation.canvas.aspectRatio, contentMode: .fit)
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(isRecording ? Color.red : Color.clear, lineWidth: 1)
        }
        .accessibilityLabel("Live selected screen and camera preview")
    }

    @ViewBuilder
    private func cameraPreview(session: AVCaptureSession) -> some View {
        if presentation.resolvedCameraBackground.mode == .off {
            CameraLivePreview(session: session)
        } else if let cameraImage {
            Image(nsImage: cameraImage)
                .resizable()
                .scaledToFill()
        } else {
            CameraLivePreview(session: session)
                .opacity(0.35)
                .overlay { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder
    private func trackedScreenPreview(image: NSImage) -> some View {
        if presentation.framing.mode == .followCursor {
            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
                CroppedScreenPreview(
                    image: image,
                    canvas: presentation.canvas,
                    framing: followCursorFraming()
                )
            }
        } else {
            CroppedScreenPreview(
                image: image,
                canvas: presentation.canvas,
                framing: presentation.framing
            )
        }
    }

    private func followCursorFraming() -> ScreenFramingSnapshot {
        guard let selectedDisplayID,
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                      == selectedDisplayID
              }) else {
            var fallback = presentation.framing
            fallback.mode = .fixedRegion
            return fallback
        }
        let cursor = NSEvent.mouseLocation
        let frame = screen.frame
        return ScreenFramingSnapshot(
            mode: .fixedRegion,
            centerX: (cursor.x - frame.minX) / frame.width,
            centerY: 1 - (cursor.y - frame.minY) / frame.height,
            scale: presentation.framing.scale
        ).validated()
    }

    private func sourceShape(for placement: SourcePlacementSnapshot, size: CGSize) -> AnyShape {
        switch placement.shape {
        case .rectangle:
            AnyShape(Rectangle())
        case .roundedRectangle:
            AnyShape(RoundedRectangle(cornerRadius: placement.effectiveCornerRadius * min(size.width, size.height)))
        case .circle:
            AnyShape(Ellipse())
        }
    }

    private func screenDragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($screenDrag) { value, state, _ in
                guard !isLocked else { return }
                state = value.translation
            }
            .onEnded { value in
                guard !isLocked, size.width > 0, size.height > 0 else { return }
                presentation.screen.centerX += value.translation.width / size.width
                presentation.screen.centerY += value.translation.height / size.height
                presentation = presentation.validated()
            }
    }

    private func cameraDragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($cameraDrag) { value, state, _ in
                guard !isLocked else { return }
                state = value.translation
            }
            .onEnded { value in
                guard !isLocked, size.width > 0, size.height > 0 else { return }
                presentation.camera.centerX += value.translation.width / size.width
                presentation.camera.centerY += value.translation.height / size.height
                presentation = presentation.validated()
            }
    }
}

private struct SceneSwitcherBar: View {
    let scenes: [StudioScenePreset]
    let selectedSceneID: UUID?
    let isLive: Bool
    let canManage: Bool
    let incompatibility: (StudioScenePreset) -> StudioSceneLiveIncompatibility?
    let onSelect: (StudioScenePreset) -> Void
    let onSave: () -> Void
    let onCreate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label("Scenes", systemImage: "rectangle.3.group")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if scenes.isEmpty {
                Button("Save current scene", action: onSave)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canManage)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(scenes) { scene in
                            let issue = incompatibility(scene)
                            Button { onSelect(scene) } label: {
                                HStack(spacing: 6) {
                                    if scene.id == selectedSceneID, isLive {
                                        Circle().fill(.red).frame(width: 6, height: 6)
                                    }
                                    Text(scene.name).lineLimit(1)
                                    if issue != nil {
                                        Image(systemName: "lock.fill").font(.caption2)
                                    }
                                }
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .frame(minHeight: 34)
                                .contentShape(Rectangle())
                                .background(
                                    scene.id == selectedSceneID
                                        ? Color.accentColor.opacity(0.16)
                                        : Color.primary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                            .help(issue?.message ?? "Switch to \(scene.name)")
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            if canManage {
                Button(action: onSave) {
                    Image(systemName: selectedSceneID == nil ? "square.and.arrow.down" : "arrow.triangle.2.circlepath")
                }
                .help(selectedSceneID == nil ? "Save current scene" : "Update selected scene")
                .disabled(scenes.isEmpty && selectedSceneID != nil)

                Button(action: onCreate) {
                    Image(systemName: "plus")
                }
                .help("Create scene from current layout")

                if selectedSceneID != nil {
                    Menu {
                        Button("Delete Scene", systemImage: "trash", role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 28)
                }
            } else {
                Text("LIVE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.red)
            }
        }
        .frame(minHeight: 36)
        .padding(.horizontal, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

private struct StreamPreflightSummaryView: View {
    let report: StreamPreflightReport?
    let isRunning: Bool
    let onRun: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusIcon
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Stream check")
                        .font(.caption.weight(.semibold))
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(summaryColor)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button(report == nil ? "Run" : "Rerun", action: onRun)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRunning)
            }
            .frame(minHeight: 34)
            .contentShape(Rectangle())

            if let blocker = report?.blockers.first {
                Label(blocker.title, systemImage: "xmark.octagon.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            if let report {
                DisclosureGroup(isExpanded: $isExpanded) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(report.checks) { check in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: iconName(for: check.state))
                                    .foregroundStyle(color(for: check.state))
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(check.title)
                                        .font(.caption.weight(.medium))
                                    Text(check.detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                    }
                } label: {
                    Text(isExpanded ? "Hide details" : "Show \(report.checks.count) checks")
                        .font(.caption2.weight(.medium))
                }
                .tint(.secondary)
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isRunning {
            ProgressView().controlSize(.small)
        } else if let report {
            Image(systemName: report.canStart ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(report.canStart ? .green : .red)
        } else {
            Image(systemName: "checklist")
                .foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        if isRunning { return "Checking configuration…" }
        guard let report else { return "Required before streaming" }
        if !report.blockers.isEmpty {
            return "\(report.blockers.count) blocker\(report.blockers.count == 1 ? "" : "s")"
        }
        if !report.warnings.isEmpty {
            return "Ready · \(report.warnings.count) warning\(report.warnings.count == 1 ? "" : "s")"
        }
        return "Ready"
    }

    private var summaryColor: Color {
        guard let report else { return .secondary }
        return report.canStart ? (report.warnings.isEmpty ? .green : .orange) : .red
    }

    private func iconName(for state: StreamPreflightCheckState) -> String {
        switch state {
        case .passed: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .blocked: "xmark.octagon.fill"
        }
    }

    private func color(for state: StreamPreflightCheckState) -> Color {
        switch state {
        case .passed: .green
        case .warning: .orange
        case .blocked: .red
        }
    }
}

private struct CroppedScreenPreview: View {
    let image: NSImage
    let canvas: CaptureCanvasSnapshot
    let framing: ScreenFramingSnapshot

    var body: some View {
        GeometryReader { proxy in
            let sourceSize = image.size
            let sourceRect = previewSourceRect(for: sourceSize)
            let scale = max(
                proxy.size.width / max(sourceRect.width, 1),
                proxy.size.height / max(sourceRect.height, 1)
            )
            Image(nsImage: image)
                .resizable()
                .frame(width: sourceSize.width * scale, height: sourceSize.height * scale)
                .offset(
                    x: (proxy.size.width - sourceRect.width * scale) / 2 - sourceRect.minX * scale,
                    y: (proxy.size.height - sourceRect.height * scale) / 2 - sourceRect.minY * scale
                )
        }
        .clipped()
    }

    private func previewSourceRect(for sourceSize: CGSize) -> CGRect {
        guard framing.mode == .fixedRegion else {
            return CGRect(origin: .zero, size: sourceSize)
        }
        return CaptureGeometryPlanner.sourceRect(
            displaySize: sourceSize,
            canvasSize: canvas.pixelSize,
            framing: framing
        )
    }
}
