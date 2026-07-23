@preconcurrency import AVFoundation
import Foundation

enum RecordingRetentionFinalizerError: LocalizedError {
    case missingScreenTrack
    case missingAudioStems
    case unreadableProgramMovie

    var errorDescription: String? {
        switch self {
        case .missingScreenTrack:
            "The composed program movie could not be created because no screen track is available."
        case .missingAudioStems:
            "The composed program movie could not be created because the independent audio stems are unavailable."
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
        cursorTimeline: CursorSceneTimeline?,
        shortcutTimeline: SafeShortcutTimeline? = nil,
        sceneTimeline: StudioSceneTimeline? = nil,
        editTimeline: ProjectEditTimeline? = nil,
        progress: @escaping (_ fraction: Double, _ phase: String) -> Void = { _, _ in }
    ) async throws {
        guard request.storage.resolvedRetentionPolicy == .programOnly else {
            progress(0.2, "Closing recording package…")
            try projectStore.close(project)
            progress(1, "Recording saved")
            return
        }

        progress(0.04, "Preparing final video…")
        let tracks = project.manifest.tracks ?? []
        guard let screen = preferredScreenTrack(in: tracks, primaryDisplayID: request.primaryAudioDisplayID),
              let screenURL = projectStore.rawTrackURL(for: screen.id, in: project) else {
            throw RecordingRetentionFinalizerError.missingScreenTrack
        }
        let screenAsset = AVURLAsset(url: screenURL)
        let duration = try await screenAsset.load(.duration).seconds
        let timeline = if let editTimeline,
                          editTimeline.trackID == screen.id,
                          abs(editTimeline.sourceDuration - duration) < 0.1 {
            editTimeline
        } else {
            try ProjectEditTimeline(trackID: screen.id, sourceDuration: duration)
        }
        let camera = tracks.first { $0.kind == .camera }
        let cameraURL = camera.flatMap { projectStore.rawTrackURL(for: $0.id, in: project) }
        let audioStem = tracks.first { $0.kind == .audio }
        let events = projectStore.journalEvents(for: project)
        let legacyAudio = request.primaryAudioDisplayID.flatMap { displayID in
            tracks.first { $0.kind == .screen && $0.displayID == displayID }
        } ?? screen
        let audioURL: URL?
        let expectedAudioTrackCount: Int
        if let audioStem {
            guard let stemURL = projectStore.rawTrackURL(for: audioStem.id, in: project),
                  fileManager.fileExists(atPath: stemURL.path),
                  events.contains(where: {
                      $0.trackID == audioStem.id && $0.kind == .trackFinished
                  }),
                  !events.contains(where: {
                      $0.trackID == audioStem.id && $0.kind == .trackFailed
                  }) else {
                throw RecordingRetentionFinalizerError.missingAudioStems
            }
            audioURL = stemURL
            expectedAudioTrackCount = [
                request.audio.capturesSystemAudio,
                request.audio.capturesMicrophone,
            ].filter(\.self).count
        } else {
            // Schema 1/2 projects embedded their mixed audio in the primary screen movie.
            audioURL = projectStore.rawTrackURL(for: legacyAudio.id, in: project)
            expectedAudioTrackCount = 0
        }
        let programURL = project.rootURL.appending(path: Self.programTrack.relativePath)

        try projectStore.markPrepared(trackID: Self.programTrack.id, in: project)
        progress(0.12, "Rendering final video…")
        try await renderer.exportMovie(
            sources: ProjectProgramSources(
                screenURL: screenURL,
                screenSources: tracks.filter { $0.kind == .screen }.compactMap { track in
                    projectStore.rawTrackURL(for: track.id, in: project).map {
                        ProjectScreenSource(url: $0, displayID: track.displayID)
                    }
                },
                cameraURL: cameraURL,
                audioURL: audioURL,
                screenDisplayID: request.profile.programDisplayID ?? screen.displayID,
                cursorTimeline: cursorTimeline,
                shortcutTimeline: shortcutTimeline,
                sceneTimeline: sceneTimeline,
                screenWasCapturedAsFixedRegion: request.presentation.framing.mode == .fixedRegion,
                cameraTimeOffset: camera.map {
                    ProjectTrackTiming.offset(from: screen.id, to: $0.id, in: events)
                        + request.profile.resolvedCameraSyncOffset
                } ?? 0,
                rendersCursor: request.profile.includeCursor
                    && request.profile.resolvedCursorRendering == .composited,
                frameRate: request.profile.frameRate
            ),
            timeline: timeline,
            presentation: request.presentation,
            codecPolicy: request.profile.codecPolicy,
            to: programURL,
            progress: { exportProgress in
                progress(0.12 + exportProgress * 0.72, "Rendering final video…")
            }
        )
        progress(0.88, "Verifying saved video…")
        guard await isReadableProgramMovie(
            at: programURL,
            minimumAudioTrackCount: expectedAudioTrackCount
        ) else {
            throw RecordingRetentionFinalizerError.unreadableProgramMovie
        }

        try projectStore.markStarted(trackID: Self.programTrack.id, in: project)
        try projectStore.markFinished(trackID: Self.programTrack.id, in: project)
        progress(0.94, "Closing recording package…")
        try projectStore.close(project, replacingTracks: [Self.programTrack])

        // The manifest now points at a verified program movie. Removing raw tracks after
        // that atomic replacement makes interruption safe: a crash can only leave extras.
        let rawTracksURL = project.rootURL.appending(path: "raw-tracks", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: rawTracksURL.path) {
            try? fileManager.removeItem(at: rawTracksURL)
        }
        let editURL = project.rootURL.appending(path: ProjectEditStore.filename)
        if fileManager.fileExists(atPath: editURL.path) {
            try? fileManager.removeItem(at: editURL)
        }
        let shortcutTimelineURL = project.rootURL.appending(path: "scene/shortcuts.json")
        if fileManager.fileExists(atPath: shortcutTimelineURL.path) {
            try? fileManager.removeItem(at: shortcutTimelineURL)
        }
        progress(1, "Recording saved")
    }

    private func preferredScreenTrack(
        in tracks: [RecordingTrackDescriptor],
        primaryDisplayID: UInt32?
    ) -> RecordingTrackDescriptor? {
        primaryDisplayID.flatMap { displayID in
            tracks.first { $0.kind == .screen && $0.displayID == displayID }
        } ?? tracks.first { $0.kind == .screen }
    }

    private func isReadableProgramMovie(at url: URL, minimumAudioTrackCount: Int) async -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isReadable)) == true,
              let duration = try? await asset.load(.duration),
              duration.isNumeric,
              duration > .zero,
              let videoTracks = try? await asset.loadTracks(withMediaType: .video),
              !videoTracks.isEmpty,
              let audioTracks = try? await asset.loadTracks(withMediaType: .audio),
              audioTracks.count >= minimumAudioTrackCount else {
            return false
        }
        return true
    }
}
