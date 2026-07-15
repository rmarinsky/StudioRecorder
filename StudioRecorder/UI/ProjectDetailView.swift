import AppKit
import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct ProjectDetailView: View {
    let project: RecordingProjectSnapshot
    let onClose: () -> Void

    @State private var selectedTrackID: String?
    @State private var player: AVPlayer
    @State private var isExporting = false
    @State private var exportMessage: String?
    @State private var exportError: String?

    private let exporter = ProjectMediaExporter()

    init(project: RecordingProjectSnapshot, onClose: @escaping () -> Void) {
        self.project = project
        self.onClose = onClose
        let firstTrack = project.tracks.first
        _selectedTrackID = State(initialValue: firstTrack?.id)
        if let firstTrack {
            _player = State(initialValue: AVPlayer(url: project.rootURL.appending(path: firstTrack.relativePath)))
        } else {
            _player = State(initialValue: AVPlayer())
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let selectedTrackURL, FileManager.default.fileExists(atPath: selectedTrackURL.path) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 14) {
                        NativeVideoPlayer(player: player)
                            .background(Color.black)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(.primary.opacity(0.10), lineWidth: 0.5)
                            }
                            .accessibilityLabel("Recorded screen track preview")

                        shareActions(for: selectedTrackURL)
                    }
                    .padding(22)
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
        .onChange(of: selectedTrackID) { _, _ in loadSelectedTrack() }
        .onDisappear { player.pause() }
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
                Text("Recording · \(project.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.headline)
                Text("\(project.displayCount) display\(project.displayCount == 1 ? "" : "s") · \(project.captureProfile)")
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
                Text("RAW TRACKS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                ForEach(project.tracks) { track in
                    Button {
                        selectedTrackID = track.id
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedTrackID == track.id ? "play.rectangle.fill" : "play.rectangle")
                                .foregroundStyle(selectedTrackID == track.id ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(trackTitle(track)).font(.subheadline.weight(.medium))
                                Text(trackDetail(track)).font(.caption2).foregroundStyle(.secondary)
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

                Text("Raw tracks stay unchanged. Screenshots and GIFs are separate share files made from the current playhead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(14)
            }
        }
    }

    private func shareActions(for trackURL: URL) -> some View {
        HStack(spacing: 10) {
            Button("Save Frame", systemImage: "photo") { exportScreenshot(from: trackURL) }
                .keyboardShortcut("s", modifiers: [.command, .shift])

            Button("Make 5s GIF", systemImage: "sparkles.rectangle.stack") { exportGIF(from: trackURL) }
                .keyboardShortcut("g", modifiers: [.command, .shift])

            if isExporting {
                ProgressView().controlSize(.small).padding(.leading, 2)
            }

            Label("Drag Movie", systemImage: "arrow.up.right.square")
                .font(.caption)
                .foregroundStyle(.secondary)
                .draggable(trackURL)
                .help("Drag the raw movie into Finder or another app")

            Spacer()

            Button("Open Movie", systemImage: "arrow.up.forward.app") {
                NSWorkspace.shared.open(trackURL)
            }

            ShareLink(item: trackURL) {
                Label("Share Movie", systemImage: "square.and.arrow.up")
            }
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

    private func loadSelectedTrack() {
        player.pause()
        player.replaceCurrentItem(with: selectedTrackURL.map(AVPlayerItem.init(url:)))
    }

    private func exportScreenshot(from sourceURL: URL) {
        guard let destinationURL = saveURL(type: .png, suggestedName: "Recording frame.png") else { return }
        let seconds = player.currentTime().seconds
        performExport(success: "Screenshot saved") {
            try await exporter.exportScreenshot(
                from: sourceURL,
                at: seconds.isFinite ? seconds : 0,
                to: destinationURL
            )
        }
    }

    private func exportGIF(from sourceURL: URL) {
        guard let destinationURL = saveURL(type: .gif, suggestedName: "Recording clip.gif") else { return }
        let seconds = player.currentTime().seconds
        performExport(success: "GIF saved") {
            try await exporter.exportGIF(
                from: sourceURL,
                settings: GIFExportSettings(startTime: seconds.isFinite ? max(seconds, 0) : 0),
                to: destinationURL
            )
        }
    }

    private func performExport(
        success message: String,
        operation: @escaping @Sendable () async throws -> Void
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
        guard let displayID = track.displayID else { return "Screen track" }
        return project.sources.first(where: { $0.displayID == displayID })?.name ?? "Display \(displayID)"
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
        case .needsRecovery: "Needs recovery"
        case .unreadable: "Unreadable"
        }
    }

    private var lifecycleIcon: String {
        switch project.lifecycle {
        case .finalized: "checkmark.circle.fill"
        case .needsRecovery, .unreadable: "exclamationmark.triangle.fill"
        case .recording: "record.circle"
        case .finalizing: "clock"
        }
    }

    private var lifecycleColor: Color {
        switch project.lifecycle {
        case .finalized: .green
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
