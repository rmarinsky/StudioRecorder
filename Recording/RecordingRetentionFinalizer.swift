@preconcurrency import AVFoundation
import Foundation

enum RecordingRetentionFinalizerError: LocalizedError {
    case missingScreenTrack
    case unreadableProgramMovie

    var errorDescription: String? {
        switch self {
        case .missingScreenTrack:
            "The composed program movie could not be created because no screen track is available."
        case .unreadableProgramMovie:
            "The composed program movie did not pass media verification."
        }
    }
}

@MainActor
final class RecordingRetentionFinalizer {
    static let programTrack = RecordingTrackDescriptor.program

    private let renderer: ProjectProgramRenderer
    private let fileManager: FileManager

    init(
        renderer: ProjectProgramRenderer = ProjectProgramRenderer(),
        fileManager: FileManager = .default
    ) {
        self.renderer = renderer
        self.fileManager = fileManager
    }

    func finalize(
        project: RecordingProject,
        request: CaptureRequest,
        projectStore: RecordingProjectStore,
        cursorTimeline: CursorSceneTimeline?
    ) async throws {
        guard request.storage.resolvedRetentionPolicy == .programOnly else {
            try projectStore.close(project)
            return
        }

        let tracks = project.manifest.tracks ?? []
        guard let screen = preferredScreenTrack(in: tracks, primaryDisplayID: request.primaryAudioDisplayID),
              let screenURL = projectStore.rawTrackURL(for: screen.id, in: project) else {
            throw RecordingRetentionFinalizerError.missingScreenTrack
        }
        let screenAsset = AVURLAsset(url: screenURL)
        let duration = try await screenAsset.load(.duration).seconds
        let timeline = try ProjectEditTimeline(trackID: screen.id, sourceDuration: duration)
        let camera = tracks.first { $0.kind == .camera }
        let cameraURL = camera.flatMap { projectStore.rawTrackURL(for: $0.id, in: project) }
        let audio = request.primaryAudioDisplayID.flatMap { displayID in
            tracks.first { $0.kind == .screen && $0.displayID == displayID }
        } ?? screen
        let audioURL = projectStore.rawTrackURL(for: audio.id, in: project)
        let events = projectStore.journalEvents(for: project)
        let programURL = project.rootURL.appending(path: Self.programTrack.relativePath)

        try projectStore.markPrepared(trackID: Self.programTrack.id, in: project)
        try await renderer.exportMovie(
            sources: ProjectProgramSources(
                screenURL: screenURL,
                cameraURL: cameraURL,
                audioURL: audioURL,
                screenDisplayID: screen.displayID,
                cursorTimeline: cursorTimeline,
                cameraTimeOffset: camera.map {
                    ProjectTrackTiming.offset(from: screen.id, to: $0.id, in: events)
                } ?? 0,
                rendersCursor: request.profile.includeCursor
                    && request.profile.resolvedCursorRendering == .composited
            ),
            timeline: timeline,
            presentation: request.presentation,
            to: programURL
        )
        guard await isReadableProgramMovie(at: programURL) else {
            throw RecordingRetentionFinalizerError.unreadableProgramMovie
        }

        try projectStore.markStarted(trackID: Self.programTrack.id, in: project)
        try projectStore.markFinished(trackID: Self.programTrack.id, in: project)
        try projectStore.close(project, replacingTracks: [Self.programTrack])

        // The manifest now points at a verified program movie. Removing raw tracks after
        // that atomic replacement makes interruption safe: a crash can only leave extras.
        let rawTracksURL = project.rootURL.appending(path: "raw-tracks", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: rawTracksURL.path) {
            try? fileManager.removeItem(at: rawTracksURL)
        }
    }

    private func preferredScreenTrack(
        in tracks: [RecordingTrackDescriptor],
        primaryDisplayID: UInt32?
    ) -> RecordingTrackDescriptor? {
        primaryDisplayID.flatMap { displayID in
            tracks.first { $0.kind == .screen && $0.displayID == displayID }
        } ?? tracks.first { $0.kind == .screen }
    }

    private func isReadableProgramMovie(at url: URL) async -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isReadable)) == true,
              let duration = try? await asset.load(.duration),
              duration.isNumeric,
              duration > .zero,
              let tracks = try? await asset.loadTracks(withMediaType: .video),
              !tracks.isEmpty else {
            return false
        }
        return true
    }
}
