import AppKit
import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct TimelapseSettingsControls: View {
    @Binding var settings: TimelapseSettings
    let captureIntervalEditable: Bool
    let isDisabled: Bool

    private let frameDurations: [TimeInterval] = [0.1, 0.2, 0.3, 0.4, 0.5]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Stepper(value: $settings.captureInterval, in: 1...60, step: 1) {
                Text("Capture every \(Int(settings.captureInterval)) s")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(isDisabled || !captureIntervalEditable)

            Picker("Frame duration", selection: $settings.frameDuration) {
                ForEach(frameDurations, id: \.self) { duration in
                    Text(String(format: "%.1f s", duration)).tag(duration)
                }
            }
            .disabled(isDisabled)

            Picker("Transition", selection: $settings.transition) {
                ForEach(TimelapseTransition.allCases) { transition in
                    Text(transition.label).tag(transition)
                }
            }
            .disabled(isDisabled)

            Label(String(format: "%.1f× playback speed", settings.speedMultiplier), systemImage: "speedometer")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Text(captureIntervalEditable
                 ? "Saves the whole scene as silent selected frames. Change playback after capture without recapturing."
                 : "Capture interval is fixed for this recording. Change frame duration and transition, then render again.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }
}

struct TimelapseProjectView: View {
    let project: RecordingProjectSnapshot
    let jobs: [RecordingJob]
    let onClose: () -> Void
    let enqueueRender: (UUID, TimelapseSettings) async throws -> Void

    @State private var settings: TimelapseSettings
    @State private var renderDocument: TimelapseRenderDocument?
    @State private var sourceFrameCount = 0
    @State private var player: AVPlayer?
    @State private var isQueueingRender = false
    @State private var isExporting = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    init(
        project: RecordingProjectSnapshot,
        jobs: [RecordingJob],
        onClose: @escaping () -> Void,
        enqueueRender: @escaping (UUID, TimelapseSettings) async throws -> Void
    ) {
        self.project = project
        self.jobs = jobs
        self.onClose = onClose
        self.enqueueRender = enqueueRender
        _settings = State(initialValue: project.timelapse ?? TimelapseSettings())
    }

    private var programURL: URL? {
        guard let track = project.tracks.first(where: { $0.kind == .program }) else { return nil }
        return project.rootURL.appending(path: track.relativePath)
    }

    private var activeRenderJob: RecordingJob? {
        jobs.filter { $0.projectID == project.identity.manifestID && $0.kind == .timelapseRender }
            .max { $0.updatedAt < $1.updatedAt }
    }

    private var isRendering: Bool {
        activeRenderJob?.state == .queued || activeRenderJob?.state == .running
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("Projects", systemImage: "chevron.left", action: onClose)
                    .buttonStyle(.plain)
                Divider().frame(height: 20)
                Label(project.recordingName ?? "Timelapse", systemImage: "timelapse")
                    .font(.headline)
                Spacer()
                Button("Export Movie…", systemImage: "square.and.arrow.up", action: exportMovie)
                    .disabled(isExporting || !hasProgramMovie)
                if isExporting { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 18)
            .frame(height: 52)

            Divider()

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    Group {
                        if let player, hasProgramMovie {
                            VideoPlayer(player: player)
                                .aspectRatio(videoAspectRatio, contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.black)
                        } else if project.lifecycle == .finalizing {
                            ContentUnavailableView(
                                "Preparing timelapse",
                                systemImage: "clock.arrow.2.circlepath",
                                description: Text("The selected frames are being rendered into a movie.")
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ContentUnavailableView(
                                "Movie not available",
                                systemImage: "film.stack",
                                description: Text("The captured frames are preserved in this project. Retry the render from Jobs if it failed.")
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(minHeight: 300)

                    HStack(spacing: 20) {
                        Label("\(renderDocument?.report.sourceFrameCount ?? projectFrameCount) selected frames", systemImage: "photo.stack")
                        Label("Silent", systemImage: "speaker.slash")
                        if let report = renderDocument?.report, report.blendedMotionTransitions > 0 {
                            Label("\(report.blendedMotionTransitions) motion transitions", systemImage: "arrow.left.and.right")
                        }
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 14) {
                    Text("Playback")
                        .font(.title3.weight(.semibold))
                    TimelapseSettingsControls(
                        settings: $settings,
                        captureIntervalEditable: false,
                        isDisabled: isQueueingRender || isRendering
                    )
                    .padding(.horizontal, -14)

                    Button(action: queueRender) {
                        if isQueueingRender || isRendering {
                            ProgressView().controlSize(.small)
                            Text("Rendering…")
                        } else {
                            Label("Apply and render", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isQueueingRender || isRendering || projectFrameCount == 0)

                    if let job = activeRenderJob, job.state == .failed {
                        Label(job.failure ?? "Render failed. Retry by applying the settings again.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if let job = activeRenderJob, job.state == .running || job.state == .queued {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.stage).font(.caption.weight(.medium))
                            ProgressView(value: job.progress)
                        }
                    }

                    if let report = renderDocument?.report, report.motionFallbackTransitions > 0 {
                        Text("\(report.motionFallbackTransitions) transitions used frame blending because motion could not be estimated reliably.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let statusMessage {
                        Label(statusMessage, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(width: 300, alignment: .leading)
                .padding(18)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(18)
        }
        .task { await reloadMovie() }
        .onChange(of: activeRenderJob?.state) { _, state in
            guard state == .completed else { return }
            Task { await reloadMovie() }
        }
    }

    private var hasProgramMovie: Bool {
        guard let programURL else { return false }
        return FileManager.default.fileExists(atPath: programURL.path)
    }

    private var projectFrameCount: Int {
        renderDocument?.report.sourceFrameCount ?? sourceFrameCount
    }

    private var videoAspectRatio: CGFloat {
        guard let presentation = project.presentation else { return 16 / 9 }
        let canvas = presentation.canvas.pixelSize
        return canvas.height > 0 ? canvas.width / canvas.height : 16 / 9
    }

    @MainActor
    private func reloadMovie() async {
        renderDocument = try? TimelapseRenderDocument.load(in: project.rootURL)
        if let savedSettings = renderDocument?.settings { settings = savedSettings }
        if let sourceTrack = project.tracks.first(where: { $0.kind == .timelapse }) {
            let sourceURL = project.rootURL.appending(path: sourceTrack.relativePath)
            if FileManager.default.fileExists(atPath: sourceURL.path) {
                let seconds = (try? await AVURLAsset(url: sourceURL).load(.duration).seconds) ?? 0
                sourceFrameCount = max(Int(seconds.rounded()), 0)
            }
        }
        guard let programURL, FileManager.default.fileExists(atPath: programURL.path) else {
            player?.pause()
            player = nil
            return
        }
        player?.pause()
        player = AVPlayer(url: programURL)
    }

    private func queueRender() {
        guard !isQueueingRender, !isRendering else { return }
        isQueueingRender = true
        errorMessage = nil
        statusMessage = nil
        Task {
            defer { isQueueingRender = false }
            do {
                guard let projectID = project.identity.manifestID else {
                    throw RecordingJobStoreError.invalidJob
                }
                try await enqueueRender(projectID, settings.validated())
                statusMessage = "Render queued in Jobs"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func exportMovie() {
        guard let programURL, FileManager.default.fileExists(atPath: programURL.path) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(project.recordingName ?? "Timelapse").mov"
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        let didStartAccess = destinationURL.startAccessingSecurityScopedResource()
        isExporting = true
        errorMessage = nil
        statusMessage = nil
        Task {
            defer {
                isExporting = false
                if didStartAccess { destinationURL.stopAccessingSecurityScopedResource() }
            }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try TimelapseMovieCopier.copy(from: programURL, to: destinationURL)
                }.value
                statusMessage = "Movie exported"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private enum TimelapseMovieCopier {
    static func copy(from sourceURL: URL, to destinationURL: URL) throws {
        guard sourceURL.standardizedFileURL != destinationURL.standardizedFileURL,
              !destinationURL.pathComponents.contains(where: { $0.hasSuffix(".recordingproject") }) else {
            throw ProjectEditRendererError.unsafeDestination
        }
        let fileManager = FileManager.default
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appending(path: ".\(destinationURL.lastPathComponent).\(UUID().uuidString).mov")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }
}
