import AppKit
@preconcurrency import AVFoundation
import AVKit
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

struct GIFMakerSource: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let suggestedName: String
    let initialStartTime: TimeInterval
}

private enum GIFQualityPreset: String, CaseIterable, Identifiable {
    case chat
    case docs
    case smooth
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chat: "Chat · smallest"
        case .docs: "Docs · balanced"
        case .smooth: "Smooth · high quality"
        case .custom: "Custom"
        }
    }

    var values: (width: Int, framesPerSecond: Double)? {
        switch self {
        case .chat: (480, 5)
        case .docs: (720, 10)
        case .smooth: (960, 15)
        case .custom: nil
        }
    }
}

struct GIFMakerView: View {
    let source: GIFMakerSource
    let onDismiss: () -> Void

    @State private var player: AVPlayer
    @State private var sourceDuration: TimeInterval = 0
    @State private var sourceAspectRatio: CGFloat = 16 / 9
    @State private var startTime: TimeInterval
    @State private var clipDuration: TimeInterval = 5
    @AppStorage("gifMakerFramesPerSecond") private var framesPerSecond = 10.0
    @AppStorage("gifMakerMaxPixelWidth") private var maxPixelWidth = 720
    @AppStorage("gifMakerLoops") private var loops = true
    @State private var isLoading = true
    @State private var isExporting = false
    @State private var resultURL: URL?
    @State private var resultBytes: Int64?
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var exportTask: Task<Void, Never>?
    @State private var exportID = UUID()
    @State private var previewTask: Task<Void, Never>?

    private let exporter = ProjectMediaExporter()

    init(source: GIFMakerSource, onDismiss: @escaping () -> Void) {
        self.source = source
        self.onDismiss = onDismiss
        _player = State(initialValue: AVPlayer(url: source.url))
        _startTime = State(initialValue: max(source.initialStartTime, 0))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HStack(alignment: .top, spacing: 0) {
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                controls
                    .frame(width: 310)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(.bar)
            }
        }
        .frame(minWidth: 820, idealWidth: 940, minHeight: 590, idealHeight: 650)
        .task { await loadSource() }
        .onChange(of: startTime) { _, next in
            cancelPreview()
            player.seek(to: CMTime(seconds: next, preferredTimescale: 600))
            clipDuration = min(clipDuration, availableDuration)
            invalidateResult()
        }
        .onChange(of: clipDuration) { _, _ in
            cancelPreview()
            invalidateResult()
        }
        .onChange(of: framesPerSecond) { _, _ in invalidateResult() }
        .onChange(of: maxPixelWidth) { _, _ in invalidateResult() }
        .onChange(of: loops) { _, _ in invalidateResult() }
        .onDisappear {
            player.pause()
            cancelPreview()
            exportTask?.cancel()
            removeResult()
        }
        .alert("GIF Creation Failed", isPresented: errorPresented) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown GIF creation error")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Make GIF").font(.headline)
                Text(source.url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Done") { onDismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }

    @ViewBuilder
    private var preview: some View {
        VStack(spacing: 14) {
            if let resultURL {
                GIFQuickLookPreview(url: resultURL)
                    .id(resultURL)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.primary.opacity(0.12), lineWidth: 0.5)
                    }

                HStack(spacing: 10) {
                    Label("GIF ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if let resultBytes {
                        Text(ByteCountFormatter.string(fromByteCount: resultBytes, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open", systemImage: "arrow.up.forward.app") {
                        NSWorkspace.shared.open(resultURL)
                    }
                    Button("Reveal", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([resultURL])
                    }
                    Button("Copy", systemImage: "doc.on.doc") { copyResult() }
                    Label("Drag", systemImage: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .draggable(resultURL)
                        .help("Drag the GIF into Finder or another app")
                    ShareLink(item: resultURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                .buttonStyle(.bordered)
            } else if isLoading {
                ProgressView("Reading video…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VideoPlayer(player: player)
                    .aspectRatio(sourceAspectRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.primary.opacity(0.12), lineWidth: 0.5)
                    }
                HStack {
                    Text("Move the start control, then use the player to inspect the source.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Preview selection", systemImage: "play.fill") { previewSelection() }
                        .buttonStyle(.bordered)
                }
            }

            if let statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                controlSection("RANGE") {
                    LabeledContent("Start") {
                        Text(formatTime(startTime)).monospacedDigit()
                    }
                    Slider(value: $startTime, in: 0...maximumStartTime)
                        .disabled(isLoading || isExporting || sourceDuration <= 0)
                        .accessibilityLabel("GIF start time")
                        .accessibilityValue(formatTime(startTime))

                    LabeledContent("Duration") {
                        Text(formatTime(clipDuration)).monospacedDigit()
                    }
                    Slider(value: $clipDuration, in: 0.1...maximumClipDuration)
                        .disabled(isLoading || isExporting || sourceDuration <= 0)
                        .accessibilityLabel("GIF duration")
                        .accessibilityValue(formatTime(clipDuration))

                    Text("Ends at \(formatTime(min(startTime + clipDuration, sourceDuration))) · up to \(frameCount) frames")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider()

                controlSection("OUTPUT") {
                    Picker("Preset", selection: qualityPresetBinding) {
                        ForEach(GIFQualityPreset.allCases) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }

                    Picker("Width", selection: $maxPixelWidth) {
                        Text("Small · 480 px").tag(480)
                        Text("Medium · 720 px").tag(720)
                        Text("Large · 960 px").tag(960)
                        Text("Maximum · 1280 px").tag(1_280)
                    }

                    Picker("Frame rate", selection: $framesPerSecond) {
                        Text("5 fps · smallest").tag(5.0)
                        Text("10 fps · balanced").tag(10.0)
                        Text("15 fps · smooth").tag(15.0)
                    }

                    Toggle("Loop continuously", isOn: $loops)

                    Text("GIF has no audio. The exact file size appears after creation.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if let resultBytes, resultBytes > 10_000_000 {
                        Label("Large for chat. Try a smaller preset or shorter range.", systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .disabled(isExporting)

                Divider()

                if let resultURL {
                    Label(resultURL.lastPathComponent, systemImage: "photo.stack")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack {
                        Button("Create again", systemImage: "arrow.clockwise") { createGIF() }
                        Button("Delete", systemImage: "trash", role: .destructive) { removeResult() }
                        Button("Save As…", systemImage: "square.and.arrow.down") { saveResult() }
                            .buttonStyle(.borderedProminent)
                    }
                } else if isExporting {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Creating GIF…").foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel", role: .cancel) { cancelExport() }
                    }
                } else {
                    Button("Create GIF", systemImage: "sparkles") { createGIF() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isLoading || sourceDuration <= 0)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(18)
        }
    }

    private func controlSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var availableDuration: TimeInterval {
        max(min(15, sourceDuration - startTime), 0.1)
    }

    private var maximumStartTime: TimeInterval {
        max(sourceDuration - 0.1, 0)
    }

    private var maximumClipDuration: TimeInterval {
        max(availableDuration, 0.1)
    }

    private var frameCount: Int {
        max(1, Int(floor(min(clipDuration, availableDuration) * framesPerSecond)))
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var qualityPresetBinding: Binding<GIFQualityPreset> {
        Binding(
            get: {
                GIFQualityPreset.allCases.first {
                    guard let values = $0.values else { return false }
                    return values.width == maxPixelWidth && values.framesPerSecond == framesPerSecond
                } ?? .custom
            },
            set: { preset in
                guard let values = preset.values else { return }
                maxPixelWidth = values.width
                framesPerSecond = values.framesPerSecond
            }
        )
    }

    private func loadSource() async {
        do {
            let asset = AVURLAsset(url: source.url)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else {
                throw ProjectMediaExportError.invalidAssetDuration
            }
            try Task.checkCancellation()
            sourceDuration = duration
            startTime = min(max(startTime, 0), max(duration - 0.1, 0))
            clipDuration = min(5, max(duration - startTime, 0.1), 15)

            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let size = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let transformed = size.applying(transform)
                let width = abs(transformed.width)
                let height = abs(transformed.height)
                if width > 0, height > 0 { sourceAspectRatio = width / height }
            }
            await player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    private func previewSelection() {
        cancelPreview()
        let previewStart = startTime
        let stopAfter = min(clipDuration, availableDuration)
        previewTask = Task { @MainActor in
            await player.seek(to: CMTime(seconds: previewStart, preferredTimescale: 600))
            guard !Task.isCancelled else { return }
            player.play()
            do {
                try await Task.sleep(for: .seconds(stopAfter))
            } catch {
                return
            }
            player.pause()
            previewTask = nil
        }
    }

    private func cancelPreview() {
        previewTask?.cancel()
        previewTask = nil
        player.pause()
    }

    private func createGIF() {
        cancelExport()
        removeResult()
        statusMessage = nil
        errorMessage = nil
        isExporting = true
        player.pause()

        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "Studio Recorder GIF Previews", directoryHint: .isDirectory)
            .appending(path: "\(UUID().uuidString).gif")
        let settings = GIFExportSettings(
            startTime: startTime,
            duration: clipDuration,
            framesPerSecond: framesPerSecond,
            maxPixelWidth: maxPixelWidth,
            loops: loops
        )
        let operationID = UUID()
        exportID = operationID

        exportTask = Task {
            do {
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try await exporter.exportGIF(from: source.url, settings: settings, to: outputURL)
                try Task.checkCancellation()
                guard exportID == operationID else {
                    try? FileManager.default.removeItem(at: outputURL)
                    return
                }
                resultBytes = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                resultURL = outputURL
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: outputURL)
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                if exportID == operationID { errorMessage = error.localizedDescription }
            }
            if exportID == operationID {
                isExporting = false
                exportTask = nil
            }
        }
    }

    private func cancelExport() {
        exportID = UUID()
        exportTask?.cancel()
        exportTask = nil
        isExporting = false
    }

    private func invalidateResult() {
        guard !isExporting else { return }
        removeResult()
        statusMessage = nil
    }

    private func removeResult() {
        if let resultURL { try? FileManager.default.removeItem(at: resultURL) }
        resultURL = nil
        resultBytes = nil
    }

    private func saveResult() {
        guard let resultURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = source.suggestedName
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try Data(contentsOf: resultURL).write(to: destination, options: .atomic)
            statusMessage = "Saved \(destination.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copyResult() {
        guard let resultURL else { return }
        guard let data = try? Data(contentsOf: resultURL) else {
            errorMessage = "Studio Recorder could not read the finished GIF."
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setData(data, forType: .init(UTType.gif.identifier)) {
            statusMessage = "GIF copied to the clipboard"
        } else {
            errorMessage = "Studio Recorder could not copy the GIF to the clipboard."
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00.0" }
        return String(format: "%d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }
}

private struct GIFQuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        view.previewItem = url as NSURL
        view.refreshPreviewItem()
    }
}
