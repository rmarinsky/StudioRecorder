import AppKit
import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct ProjectDetailView: View {
    let project: RecordingProjectSnapshot
    let onClose: () -> Void

    @State private var selectedTrackID: String?
    @State private var programScreenTrackID: String?
    @StateObject private var editSession: ProjectEditSession
    @State private var isExporting = false
    @State private var exportMessage: String?
    @State private var exportError: String?
    @State private var gifMakerSource: GIFMakerSource?
    @State private var temporaryGIFSourceURL: URL?
    @State private var gifPreparationTask: Task<Void, Never>?
    @State private var gifPreparationID = UUID()
    @State private var isPreparingGIF = false

    private let exporter = ProjectMediaExporter()

    init(project: RecordingProjectSnapshot, onClose: @escaping () -> Void) {
        self.project = project
        self.onClose = onClose
        let playableTrackIDs = Set(project.recoveryReport.tracks.compactMap { track in
            switch track.state {
            case .finalized, .partialReadable: track.id
            case .missing, .unreadable, .unknownV1: nil
            }
        })
        let firstTrack = project.tracks.first(where: { playableTrackIDs.contains($0.id) })
        let firstScreenTrack = project.tracks.first(where: {
            playableTrackIDs.contains($0.id) && ($0.kind == .screen || $0.kind == .program)
        })
        _selectedTrackID = State(initialValue: firstTrack?.id)
        _programScreenTrackID = State(initialValue: firstScreenTrack?.id)
        _editSession = StateObject(wrappedValue: ProjectEditSession())
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let programScreenTrackURL, FileManager.default.fileExists(atPath: programScreenTrackURL.path) {
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        VStack(spacing: 14) {
                            NativeVideoPlayer(player: editSession.player)
                                .background(Color.black)
                                .aspectRatio(editSession.presentation.canvas.aspectRatio, contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .frame(maxHeight: 420)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(.primary.opacity(0.10), lineWidth: 0.5)
                                }
                                .accessibilityLabel("Composed program preview")

                            ProjectQuickEditorView(session: editSession, onExportMovie: exportEditedMovie)

                            if let selectedTrackURL, FileManager.default.fileExists(atPath: selectedTrackURL.path) {
                                shareActions(for: selectedTrackURL)
                            }
                        }
                        .padding(22)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                    inspector
                        .frame(width: 300)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(.bar)
                }
            } else {
                ContentUnavailableView {
                    Label("No playable track", systemImage: "film.stack")
                } description: {
                    Text("The project package is preserved, but this track is missing or unreadable.")
                } actions: {
                    Button("Reveal Project") { revealProject() }
                }
            }
        }
        .navigationTitle("Recording")
        .task(id: programScreenTrackID) { await loadProgram() }
        .onDisappear {
            editSession.stop()
            cancelGIFPreparation()
            cleanupGIFSource()
        }
        .sheet(item: $gifMakerSource, onDismiss: cleanupGIFSource) { source in
            GIFMakerView(source: source) { gifMakerSource = nil }
        }
        .overlay(alignment: .bottom) {
            if let exportMessage {
                Label(exportMessage, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 10, y: 4)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: exportMessage)
        .alert("Export Failed", isPresented: exportErrorPresented) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "Unknown export error")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button(action: onClose) {
                Label("All Projects", systemImage: "chevron.left")
            }
            .keyboardShortcut(.escape, modifiers: [])

            Divider().frame(height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(editSession.presentation.resolvedName)
                    .font(.headline)
                Text("Recorded \(project.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(project.displayCount) display\(project.displayCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label(lifecycleLabel, systemImage: lifecycleIcon)
                .font(.caption.weight(.medium))
                .foregroundStyle(lifecycleColor)

            Button("Reveal Project", systemImage: "folder") { revealProject() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("SCENE")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                if project.lifecycle == .recovered {
                    Label("Recovered after an interrupted recording. Only verified playable tracks were retained; the original diagnostics remain in the project journal.", systemImage: "checkmark.shield.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                }

                if isProgramOnlyProject {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Scene name", text: sceneNameBinding)
                            .textFieldStyle(.roundedBorder)
                        Text("This scene layout is baked into the program movie. Independent screen and camera tracks were intentionally removed after verification.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(editSession.isWorking || !editSession.canPersistEdits)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 16)
                } else {
                    ProjectPresentationEditorView(
                        project: project,
                        screenTrack: programScreenTrack,
                        presentation: presentationBinding
                    )
                    .disabled(editSession.isWorking || !editSession.canPersistEdits)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 16)
                }

                if !editSession.isLoading, !editSession.canPersistEdits {
                    Text(isProgramOnlyProject
                        ? "The scene name is read-only because this project cannot persist versioned edits."
                        : "Program layout is read-only because this project cannot persist versioned edits.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                }

                Divider()

                Text("MEDIA · SHARING")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                ForEach(project.tracks) { track in
                    Button {
                        selectedTrackID = track.id
                        if track.kind == .screen || track.kind == .program {
                            programScreenTrackID = track.id
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedTrackID == track.id ? "square.and.arrow.up.fill" : "square.and.arrow.up")
                                .foregroundStyle(selectedTrackID == track.id ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(trackTitle(track)).font(.subheadline.weight(.medium))
                                Text(trackDetail(track)).font(.caption2).foregroundStyle(.secondary)
                                if track.id == programScreenTrackID {
                                    Text(track.kind == .program ? "Composed program movie" : "Program screen source")
                                        .font(.caption2)
                                        .foregroundStyle(Color.accentColor)
                                }
                                if track.id == selectedTrackID {
                                    Text("Selected for sharing").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if selectedTrackID == track.id {
                                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(selectedTrackID == track.id ? Color.accentColor.opacity(0.10) : Color.clear)
                    }
                    .buttonStyle(.plain)
                    .disabled(editSession.isWorking)
                    Divider()
                }

                Text("PROJECT")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 18)
                    .padding(.bottom, 8)

                metadataRow("Created", value: project.createdAt.formatted(date: .abbreviated, time: .shortened))
                metadataRow("Status", value: lifecycleLabel)
                metadataRow("Format", value: "Recoverable package")

                Text(isProgramOnlyProject
                    ? "The verified program movie is the retained source. edit.json stores non-destructive cuts and the scene name."
                    : "Raw tracks stay unchanged. edit.json stores cuts and program layout; screenshots, GIFs, and edited movies are derived files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(14)
            }
        }
    }

    private func shareActions(for trackURL: URL) -> some View {
        HStack(spacing: 10) {
            Button("Save Frame", systemImage: "photo") { exportScreenshot() }
                .keyboardShortcut("s", modifiers: [.command, .shift])

            Button("Make GIF…", systemImage: "sparkles.rectangle.stack") { openGIFMaker() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(isPreparingGIF)

            if isPreparingGIF {
                ProgressView().controlSize(.small).padding(.leading, 2)
                Button("Cancel", role: .cancel) { cancelGIFPreparation() }
            }

            if isExporting {
                ProgressView().controlSize(.small).padding(.leading, 2)
            }

            Label("Drag Raw Movie", systemImage: "arrow.up.right.square")
                .font(.caption)
                .foregroundStyle(.secondary)
                .draggable(trackURL)
                .help("Drag the unchanged source movie without Quick Edit changes")

            Spacer()

            Button("Open Raw Movie", systemImage: "arrow.up.forward.app") {
                NSWorkspace.shared.open(trackURL)
            }
            .help("Open the unchanged source movie without Quick Edit changes")

            ShareLink(item: trackURL) {
                Label("Share Raw Movie", systemImage: "square.and.arrow.up")
            }
            .help("Share the unchanged source movie without Quick Edit changes")
        }
        .buttonStyle(.bordered)
        .disabled(isExporting)
    }

    private var selectedTrack: RecordingTrackDescriptor? {
        project.tracks.first { $0.id == selectedTrackID }
    }

    private var selectedTrackURL: URL? {
        selectedTrack.map { project.rootURL.appending(path: $0.relativePath) }
    }

    private var exportErrorPresented: Binding<Bool> {
        Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )
    }

    private var presentationBinding: Binding<CapturePresentationSnapshot> {
        Binding(
            get: { editSession.presentation },
            set: { editSession.updatePresentation($0) }
        )
    }

    private var sceneNameBinding: Binding<String> {
        Binding(
            get: { editSession.presentation.name ?? editSession.presentation.resolvedName },
            set: {
                var presentation = editSession.presentation
                presentation.name = String($0.prefix(80))
                editSession.updatePresentation(presentation)
            }
        )
    }

    private func loadProgram() async {
        guard let programScreenTrack,
              let programScreenURL = programScreenTrackURL else {
            editSession.stop()
            return
        }
        await editSession.load(
            projectID: project.identity.manifestID,
            projectRootURL: project.rootURL,
            track: programScreenTrack,
            sourceURL: programScreenURL,
            programSources: programSources,
            initialPresentation: project.presentation ?? .default
        )
    }

    private var programScreenTrack: RecordingTrackDescriptor? {
        project.tracks.first {
            $0.id == programScreenTrackID && isPlayable($0) && ($0.kind == .screen || $0.kind == .program)
        } ?? project.tracks.first { isPlayable($0) && ($0.kind == .screen || $0.kind == .program) }
    }

    private func isPlayable(_ track: RecordingTrackDescriptor) -> Bool {
        guard FileManager.default.fileExists(atPath: project.rootURL.appending(path: track.relativePath).path),
              let state = project.recoveryReport.tracks.first(where: { $0.id == track.id })?.state else {
            return false
        }
        return state == .finalized || state == .partialReadable
    }

    private var programScreenTrackURL: URL? {
        programScreenTrack.map { project.rootURL.appending(path: $0.relativePath) }
    }

    private var programSources: ProjectProgramSources? {
        guard let screen = programScreenTrack else { return nil }
        guard screen.kind == .screen else { return nil }
        let camera = project.tracks.first(where: { track in
            guard track.kind == .camera else { return false }
            let url = project.rootURL.appending(path: track.relativePath)
            let recoveryState = project.recoveryReport.tracks.first(where: { $0.id == track.id })?.state
            return FileManager.default.fileExists(atPath: url.path)
                && (recoveryState == .finalized || recoveryState == .partialReadable)
        })
        let audioTrack = project.primaryAudioDisplayID.flatMap { displayID in
            project.tracks.first { track in
                guard track.kind == .screen, track.displayID == displayID else { return false }
                let url = project.rootURL.appending(path: track.relativePath)
                let recoveryState = project.recoveryReport.tracks.first(where: { $0.id == track.id })?.state
                return FileManager.default.fileExists(atPath: url.path)
                    && (recoveryState == .finalized || recoveryState == .partialReadable)
            }
        }
        return ProjectProgramSources(
            screenURL: project.rootURL.appending(path: screen.relativePath),
            cameraURL: camera.map { project.rootURL.appending(path: $0.relativePath) },
            audioURL: audioTrack.map { project.rootURL.appending(path: $0.relativePath) },
            screenDisplayID: screen.displayID,
            cursorTimeline: cursorTimeline,
            cameraTimeOffset: camera.map {
                ProjectTrackTiming.offset(
                    from: screen.id,
                    to: $0.id,
                    in: projectJournalEvents
                )
            } ?? 0,
            rendersCursor: project.includesCursor && project.usesCompositedCursor
        )
    }

    private var projectJournalEvents: [ProjectJournalEvent] {
        let url = project.rootURL.appending(path: "journal.ndjson")
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(whereSeparator: \.isNewline).compactMap {
            try? decoder.decode(ProjectJournalEvent.self, from: Data($0.utf8))
        }
    }

    private var cursorTimeline: CursorSceneTimeline? {
        let url = project.rootURL.appending(path: "scene/cursor.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CursorSceneTimeline.self, from: data)
    }

    private func exportScreenshot() {
        guard let destinationURL = saveURL(type: .png, suggestedName: "Recording frame.png") else { return }
        let seconds = editSession.playhead
        performExport(success: "Screenshot saved") {
            let media = try await editSession.prepareMediaForDerivedExport()
            defer { media.removeIfTemporary() }
            try await exporter.exportScreenshot(
                from: media.url,
                at: seconds.isFinite ? seconds : 0,
                to: destinationURL
            )
        }
    }

    private func openGIFMaker() {
        let seconds = editSession.playhead
        cancelGIFPreparation()
        let operationID = UUID()
        gifPreparationID = operationID
        isPreparingGIF = true
        exportError = nil
        gifPreparationTask = Task {
            do {
                cleanupGIFSource()
                let media = try await editSession.prepareMediaForDerivedExport()
                guard !Task.isCancelled, gifPreparationID == operationID else {
                    media.removeIfTemporary()
                    return
                }
                temporaryGIFSourceURL = media.isTemporary ? media.url : nil
                gifMakerSource = GIFMakerSource(
                    url: media.url,
                    suggestedName: "\(editSession.presentation.resolvedName) clip.gif",
                    initialStartTime: seconds.isFinite ? max(seconds, 0) : 0
                )
            } catch is CancellationError {
                return
            } catch {
                if gifPreparationID == operationID { exportError = error.localizedDescription }
            }
            if gifPreparationID == operationID {
                isPreparingGIF = false
                gifPreparationTask = nil
            }
        }
    }

    private func cancelGIFPreparation() {
        gifPreparationID = UUID()
        gifPreparationTask?.cancel()
        gifPreparationTask = nil
        isPreparingGIF = false
    }

    private func cleanupGIFSource() {
        if let temporaryGIFSourceURL {
            try? FileManager.default.removeItem(at: temporaryGIFSourceURL)
        }
        temporaryGIFSourceURL = nil
    }

    private func exportEditedMovie() {
        guard let destinationURL = saveURL(type: .quickTimeMovie, suggestedName: "Recording edited.mov") else { return }
        performExport(success: "Edited movie saved") {
            try await editSession.exportEditedMovie(to: destinationURL)
        }
    }

    private func performExport(
        success message: String,
        operation: @escaping () async throws -> Void
    ) {
        isExporting = true
        exportError = nil
        Task {
            defer { isExporting = false }
            do {
                try await operation()
                exportMessage = message
                try? await Task.sleep(for: .seconds(2.5))
                if exportMessage == message { exportMessage = nil }
            } catch is CancellationError {
                return
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func saveURL(type: UTType, suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func revealProject() {
        NSWorkspace.shared.activateFileViewerSelecting([project.rootURL])
    }

    private func trackTitle(_ track: RecordingTrackDescriptor) -> String {
        switch track.kind {
        case .camera:
            return "Camera track"
        case .program:
            return "Program movie"
        case .screen:
            guard let displayID = track.displayID else { return "Screen track" }
            return project.sources.first(where: { $0.displayID == displayID })?.name ?? "Display \(displayID)"
        }
    }

    private var isProgramOnlyProject: Bool {
        project.tracks.count == 1 && project.tracks.first?.kind == .program
    }

    private func trackDetail(_ track: RecordingTrackDescriptor) -> String {
        guard let recovery = project.recoveryReport.tracks.first(where: { $0.id == track.id }) else {
            return track.relativePath
        }
        let size = recovery.fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return [recovery.state.label, size].compactMap { $0 }.joined(separator: " · ")
    }

    private func metadataRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private var lifecycleLabel: String {
        switch project.lifecycle {
        case .recording: "Recording"
        case .finalizing: "Finalizing"
        case .finalized: "Ready"
        case .recovered: "Recovered"
        case .needsRecovery: "Needs recovery"
        case .unreadable: "Unreadable"
        }
    }

    private var lifecycleIcon: String {
        switch project.lifecycle {
        case .finalized: "checkmark.circle.fill"
        case .recovered: "checkmark.shield.fill"
        case .needsRecovery, .unreadable: "exclamationmark.triangle.fill"
        case .recording: "record.circle"
        case .finalizing: "clock"
        }
    }

    private var lifecycleColor: Color {
        switch project.lifecycle {
        case .finalized: .green
        case .recovered: .blue
        case .needsRecovery, .unreadable: .orange
        case .recording, .finalizing: .secondary
        }
    }
}

private struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}

private extension RecordingTrackRecoveryState {
    var label: String {
        switch self {
        case .finalized: "Ready"
        case .partialReadable: "Partial"
        case .missing: "Missing"
        case .unreadable: "Unreadable"
        case .unknownV1: "Legacy"
        }
    }
}
