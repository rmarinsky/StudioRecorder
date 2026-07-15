@preconcurrency import AVFoundation
import Foundation
import SwiftUI

struct PreparedProjectMedia: Sendable {
    let url: URL
    let isTemporary: Bool

    func removeIfTemporary() {
        guard isTemporary else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

@MainActor
final class ProjectEditSession: ObservableObject {
    let player = AVPlayer()

    @Published private(set) var timeline: ProjectEditTimeline?
    @Published private(set) var presentation = CapturePresentationSnapshot.default
    @Published private(set) var privacyOverlays: [ProjectPrivacyOverlay] = []
    @Published private(set) var sceneTimeline: StudioSceneTimeline?
    @Published var selectedSegmentID: UUID?
    @Published var selectedPrivacyOverlayID: UUID?
    @Published var selectedManualZoomTransitionIndex: Int?
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?

    private let store: ProjectEditStore
    private let renderer: ProjectEditRenderer
    private let programRenderer: ProjectProgramRenderer
    private var document: ProjectEditDocument?
    private var projectRootURL: URL?
    private var sourceURL: URL?
    private var programSources: ProjectProgramSources?
    private var undoStack: [ProjectEditTimeline] = []
    private var redoStack: [ProjectEditTimeline] = []
    private var documentSaveTask: Task<Void, Never>?
    private var presentationRenderTask: Task<Void, Never>?
    private var documentRevision = 0
    private var loadID = UUID()

    init(
        store: ProjectEditStore = ProjectEditStore(),
        renderer: ProjectEditRenderer = ProjectEditRenderer(),
        programRenderer: ProjectProgramRenderer = ProjectProgramRenderer()
    ) {
        self.store = store
        self.renderer = renderer
        self.programRenderer = programRenderer
    }

    var canUndo: Bool { !undoStack.isEmpty && !isWorking }
    var canRedo: Bool { !redoStack.isEmpty && !isWorking }
    var canPersistEdits: Bool { document != nil }
    var canDeleteSelectedSegment: Bool {
        guard let timeline, let selectedSegmentID else { return false }
        return timeline.segments.count > 1 && timeline.segments.contains { $0.id == selectedSegmentID }
    }
    var isEdited: Bool {
        timeline?.isIdentity == false ||
            !privacyOverlays.isEmpty ||
            sceneTimeline != programSources?.sceneTimeline
    }
    var canEditPrivacy: Bool { canPersistEdits && timeline != nil }
    var canEditManualZoom: Bool { canPersistEdits && timeline != nil && sceneTimeline != nil }
    var manualZoomMarkers: [StudioManualZoomMarker] {
        guard let sceneTimeline, let timeline else { return [] }
        return sceneTimeline.manualZoomMarkers(sourceDuration: timeline.sourceDuration)
    }
    var playhead: TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(seconds, 0) : 0
    }

    func load(
        projectID: UUID?,
        projectRootURL: URL,
        track: RecordingTrackDescriptor,
        sourceURL: URL,
        programSources: ProjectProgramSources?,
        initialPresentation: CapturePresentationSnapshot
    ) async {
        let requestID = UUID()
        loadID = requestID
        isLoading = true
        documentRevision += 1
        documentSaveTask?.cancel()
        documentSaveTask = nil
        presentationRenderTask?.cancel()
        presentationRenderTask = nil
        defer {
            if loadID == requestID { isLoading = false }
        }

        if let pendingDocument = document, let pendingProjectRootURL = self.projectRootURL {
            do {
                try await store.save(pendingDocument, in: pendingProjectRootURL)
            } catch {
                guard loadID == requestID else { return }
                errorMessage = error.localizedDescription
                return
            }
        }
        guard loadID == requestID, !Task.isCancelled else { return }
        player.pause()
        player.replaceCurrentItem(with: nil)
        timeline = nil
        privacyOverlays = []
        sceneTimeline = nil
        document = nil
        selectedSegmentID = nil
        selectedPrivacyOverlayID = nil
        selectedManualZoomTransitionIndex = nil
        undoStack = []
        redoStack = []
        errorMessage = nil
        self.projectRootURL = projectRootURL
        self.sourceURL = sourceURL
        self.programSources = programSources
        presentation = initialPresentation.validated()
        guard let projectID else {
            player.replaceCurrentItem(with: AVPlayerItem(url: sourceURL))
            errorMessage = "Legacy projects can play raw media but cannot persist edits."
            return
        }

        do {
            let asset = AVURLAsset(url: sourceURL)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else {
                throw ProjectEditTimelineError.invalidSourceDuration
            }
            let loadedDocument = try await store.load(from: projectRootURL, expectedProjectID: projectID)
            var editDocument = loadedDocument ?? ProjectEditDocument(projectID: projectID, timelines: [])
            let loadedPresentation = (editDocument.presentation ?? initialPresentation).validated()
            let loadedSceneTimeline = editDocument.sceneTimeline ?? programSources?.sceneTimeline
            let editTimeline: ProjectEditTimeline
            if let saved = editDocument.timeline(for: track.id),
               abs(saved.sourceDuration - duration) < 0.1 {
                editTimeline = saved
            } else {
                editTimeline = try ProjectEditTimeline(trackID: track.id, sourceDuration: duration)
                editDocument.replaceTimeline(editTimeline)
            }
            sceneTimeline = loadedSceneTimeline
            let item = try await makePlayerItem(
                sourceURL: sourceURL,
                timeline: editTimeline,
                presentation: loadedPresentation,
                privacyOverlays: editDocument.privacyOverlays
            )
            try Task.checkCancellation()
            guard loadID == requestID else { return }
            document = editDocument
            timeline = editTimeline
            presentation = loadedPresentation
            privacyOverlays = editDocument.privacyOverlays
            selectedSegmentID = editTimeline.segments.first?.id
            selectedPrivacyOverlayID = editDocument.privacyOverlays.first?.id
            selectedManualZoomTransitionIndex = loadedSceneTimeline?
                .manualZoomMarkers(sourceDuration: editTimeline.sourceDuration)
                .first?.transitionIndex
            player.replaceCurrentItem(with: item)
        } catch is CancellationError {
            return
        } catch {
            guard loadID == requestID else { return }
            player.replaceCurrentItem(with: AVPlayerItem(url: sourceURL))
            errorMessage = error.localizedDescription
        }
    }

    func splitAtPlayhead() async {
        guard let current = timeline else { return }
        let newSegmentID = UUID()
        var next = current
        do {
            try next.split(at: playhead, newSegmentID: newSegmentID)
            await commitEdit(next, selectedSegmentID: newSegmentID, seekTime: playhead)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func trimStartAtPlayhead() async {
        guard let current = timeline else { return }
        var next = current
        do {
            try next.trimStart(to: playhead)
            await commitEdit(next, selectedSegmentID: next.segments.first?.id, seekTime: 0)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func trimEndAtPlayhead() async {
        guard let current = timeline else { return }
        var next = current
        do {
            try next.trimEnd(to: playhead)
            await commitEdit(next, selectedSegmentID: next.segments.last?.id, seekTime: min(playhead, next.duration))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSelectedSegment() async {
        guard let current = timeline, let selectedSegmentID else { return }
        var next = current
        do {
            try next.delete(segmentID: selectedSegmentID)
            await commitEdit(next, selectedSegmentID: next.segments.first?.id, seekTime: 0)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reset() async {
        guard let current = timeline else { return }
        errorMessage = nil
        do {
            let next = try ProjectEditTimeline(trackID: current.trackID, sourceDuration: current.sourceDuration)
            if !current.isIdentity {
                await commitEdit(next, selectedSegmentID: next.segments.first?.id, seekTime: 0)
            }
            if errorMessage == nil, !privacyOverlays.isEmpty {
                await commitPrivacyOverlays([], selectedID: nil)
            }
            if errorMessage == nil, sceneTimeline != programSources?.sceneTimeline {
                updateSceneTimeline(programSources?.sceneTimeline, selectedIndex: nil)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func undo() async {
        guard let current = timeline, let previous = undoStack.last else { return }
        await commit(
            previous,
            selectedSegmentID: previous.segments.first?.id,
            seekTime: 0,
            nextUndoStack: Array(undoStack.dropLast()),
            nextRedoStack: redoStack + [current]
        )
    }

    func redo() async {
        guard let current = timeline, let next = redoStack.last else { return }
        await commit(
            next,
            selectedSegmentID: next.segments.first?.id,
            seekTime: 0,
            nextUndoStack: undoStack + [current],
            nextRedoStack: Array(redoStack.dropLast())
        )
    }

    func exportEditedMovie(to destinationURL: URL) async throws {
        guard let sourceURL, let timeline else { throw ProjectEditRendererError.unreadableSource }
        if let renderSources = renderSources(for: sourceURL) {
            try await programRenderer.exportMovie(
                sources: renderSources,
                timeline: timeline,
                presentation: renderPresentation,
                privacyOverlays: privacyOverlays,
                to: destinationURL
            )
        } else {
            try await renderer.exportMovie(from: sourceURL, timeline: timeline, to: destinationURL)
        }
    }

    func updatePresentation(_ next: CapturePresentationSnapshot) {
        guard !isWorking, var nextDocument = document, let projectRootURL else { return }
        let validated = next.validated()
        presentation = validated
        nextDocument.replacePresentation(validated)
        document = nextDocument
        scheduleDocumentSave(in: projectRootURL)
        scheduleProgramRefresh()
    }

    func addPrivacyOverlay(style: ProjectPrivacyOverlayStyle) async {
        guard canEditPrivacy,
              let timeline,
              let sourceTime = timeline.sourceTime(at: min(playhead, max(timeline.duration - 0.001, 0))) else {
            return
        }
        let duration = max(min(3, timeline.sourceDuration - sourceTime), 0.05)
        let overlay = ProjectPrivacyOverlay(
            sourceStart: sourceTime,
            duration: duration,
            style: style
        ).validated(sourceDuration: timeline.sourceDuration)
        await commitPrivacyOverlays(privacyOverlays + [overlay], selectedID: overlay.id)
    }

    func updatePrivacyOverlay(_ overlay: ProjectPrivacyOverlay) {
        guard !isWorking,
              let timeline,
              let index = privacyOverlays.firstIndex(where: { $0.id == overlay.id }),
              var nextDocument = document,
              let projectRootURL else { return }
        var next = privacyOverlays
        next[index] = overlay.validated(sourceDuration: timeline.sourceDuration)
        privacyOverlays = next
        nextDocument.replacePrivacyOverlays(next)
        document = nextDocument
        scheduleDocumentSave(in: projectRootURL)
        scheduleProgramRefresh(force: true)
    }

    func removePrivacyOverlay(_ id: UUID) async {
        guard privacyOverlays.contains(where: { $0.id == id }) else { return }
        let next = privacyOverlays.filter { $0.id != id }
        await commitPrivacyOverlays(next, selectedID: next.first?.id)
    }

    func updateManualZoomMarker(_ marker: StudioManualZoomMarker) {
        guard !isWorking,
              let timeline,
              var next = sceneTimeline,
              next.updateManualZoomMarker(marker, sourceDuration: timeline.sourceDuration) else { return }
        updateSceneTimeline(next, selectedIndex: marker.transitionIndex)
    }

    func moveManualZoomMarkerToPlayhead(_ marker: StudioManualZoomMarker) {
        guard let timeline,
              let sourceTime = timeline.sourceTime(
                at: min(playhead, max(timeline.duration - 0.001, 0))
              ) else { return }
        var next = marker
        next.sourceTime = sourceTime
        updateManualZoomMarker(next)
    }

    func removeManualZoomMarker(_ marker: StudioManualZoomMarker) {
        guard !isWorking,
              var next = sceneTimeline,
              next.removeManualZoomMarker(at: marker.transitionIndex) else { return }
        let nextSelection = next.manualZoomMarkers(sourceDuration: timeline?.sourceDuration ?? 0).first?.transitionIndex
        updateSceneTimeline(next, selectedIndex: nextSelection)
    }

    func prepareMediaForDerivedExport() async throws -> PreparedProjectMedia {
        guard let sourceURL else { throw ProjectEditRendererError.unreadableSource }
        guard let timeline else {
            return PreparedProjectMedia(url: sourceURL, isTemporary: false)
        }
        guard !timeline.isIdentity || programSources != nil || !privacyOverlays.isEmpty else {
            return PreparedProjectMedia(url: sourceURL, isTemporary: false)
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "Studio Recorder Derived", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appending(path: "\(UUID().uuidString).mov")
        if let renderSources = renderSources(for: sourceURL) {
            try await programRenderer.exportMovie(
                sources: renderSources,
                timeline: timeline,
                presentation: renderPresentation,
                privacyOverlays: privacyOverlays,
                to: outputURL
            )
        } else {
            try await renderer.exportMovie(from: sourceURL, timeline: timeline, to: outputURL)
        }
        return PreparedProjectMedia(url: outputURL, isTemporary: true)
    }

    func stop() {
        loadID = UUID()
        documentRevision += 1
        player.pause()
        documentSaveTask?.cancel()
        presentationRenderTask?.cancel()
        if let document, let projectRootURL {
            documentSaveTask = Task { [store] in
                try? await store.save(document, in: projectRootURL)
            }
        }
    }

    private func commitEdit(
        _ next: ProjectEditTimeline,
        selectedSegmentID: UUID?,
        seekTime: TimeInterval
    ) async {
        guard let current = timeline else { return }
        await commit(
            next,
            selectedSegmentID: selectedSegmentID,
            seekTime: seekTime,
            nextUndoStack: undoStack + [current],
            nextRedoStack: []
        )
    }

    private func commit(
        _ next: ProjectEditTimeline,
        selectedSegmentID: UUID?,
        seekTime: TimeInterval,
        nextUndoStack: [ProjectEditTimeline],
        nextRedoStack: [ProjectEditTimeline]
    ) async {
        guard !isWorking,
              let sourceURL,
              let projectRootURL,
              document != nil else { return }
        documentSaveTask?.cancel()
        documentSaveTask = nil
        presentationRenderTask?.cancel()
        presentationRenderTask = nil
        let operationID = loadID
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            let item = try await makePlayerItem(
                sourceURL: sourceURL,
                timeline: next,
                presentation: presentation,
                privacyOverlays: privacyOverlays
            )
            guard loadID == operationID, var nextDocument = document else { return }
            nextDocument.replaceTimeline(next)
            try await store.save(nextDocument, in: projectRootURL)
            guard loadID == operationID else { return }
            document = nextDocument
            timeline = next
            self.selectedSegmentID = selectedSegmentID
            undoStack = nextUndoStack
            redoStack = nextRedoStack
            player.replaceCurrentItem(with: item)
            let safeSeekTime = min(max(seekTime, 0), max(next.duration - 0.001, 0))
            await player.seek(to: CMTime(seconds: safeSeekTime, preferredTimescale: 600))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func makePlayerItem(
        sourceURL: URL,
        timeline: ProjectEditTimeline,
        presentation: CapturePresentationSnapshot,
        privacyOverlays: [ProjectPrivacyOverlay]
    ) async throws -> AVPlayerItem {
        if let renderSources = renderSources(for: sourceURL, privacyOverlays: privacyOverlays) {
            return try await programRenderer.makePlayerItem(
                sources: renderSources,
                timeline: timeline,
                presentation: programSources == nil ? bakedProgramPresentation(from: presentation) : presentation,
                privacyOverlays: privacyOverlays
            )
        }
        return try await renderer.makePlayerItem(from: sourceURL, timeline: timeline)
    }

    private func scheduleProgramRefresh(force: Bool = false) {
        guard let sourceURL, let timeline, force || programSources != nil else { return }
        presentationRenderTask?.cancel()
        let operationID = loadID
        let seekTime = playhead
        let wasPlaying = player.rate != 0
        let nextPresentation = presentation
        let nextPrivacyOverlays = privacyOverlays
        presentationRenderTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(90))
                guard let self else { return }
                let item = try await self.makePlayerItem(
                    sourceURL: sourceURL,
                    timeline: timeline,
                    presentation: nextPresentation,
                    privacyOverlays: nextPrivacyOverlays
                )
                try Task.checkCancellation()
                guard self.loadID == operationID else { return }
                self.player.replaceCurrentItem(with: item)
                await self.player.seek(to: CMTime(seconds: seekTime, preferredTimescale: 600))
                if wasPlaying { self.player.play() }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.loadID == operationID else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func commitPrivacyOverlays(
        _ next: [ProjectPrivacyOverlay],
        selectedID: UUID?
    ) async {
        guard !isWorking,
              let sourceURL,
              let timeline,
              let projectRootURL,
              var nextDocument = document else { return }
        documentSaveTask?.cancel()
        presentationRenderTask?.cancel()
        let operationID = loadID
        let seekTime = playhead
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let item = try await makePlayerItem(
                sourceURL: sourceURL,
                timeline: timeline,
                presentation: presentation,
                privacyOverlays: next
            )
            guard loadID == operationID else { return }
            nextDocument.replacePrivacyOverlays(next)
            try await store.save(nextDocument, in: projectRootURL)
            guard loadID == operationID else { return }
            document = nextDocument
            privacyOverlays = next
            selectedPrivacyOverlayID = selectedID
            player.replaceCurrentItem(with: item)
            await player.seek(to: CMTime(seconds: seekTime, preferredTimescale: 600))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleDocumentSave(in projectRootURL: URL) {
        documentRevision += 1
        let revision = documentRevision
        let operationID = loadID
        documentSaveTask?.cancel()
        documentSaveTask = Task { [weak self, store] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                try Task.checkCancellation()
                guard let self,
                      self.loadID == operationID,
                      self.documentRevision == revision,
                      let document = self.document else { return }
                try await store.save(document, in: projectRootURL)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.loadID == operationID else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func updateSceneTimeline(
        _ next: StudioSceneTimeline?,
        selectedIndex: Int?
    ) {
        guard var nextDocument = document, let projectRootURL else { return }
        sceneTimeline = next
        selectedManualZoomTransitionIndex = selectedIndex
        nextDocument.replaceSceneTimeline(next)
        document = nextDocument
        scheduleDocumentSave(in: projectRootURL)
        scheduleProgramRefresh(force: true)
    }

    private func renderSources(
        for sourceURL: URL,
        privacyOverlays: [ProjectPrivacyOverlay]? = nil
    ) -> ProjectProgramSources? {
        if let programSources { return programSources.replacingSceneTimeline(sceneTimeline) }
        guard !(privacyOverlays ?? self.privacyOverlays).isEmpty else { return nil }
        return ProjectProgramSources(screenURL: sourceURL, cameraURL: nil)
    }

    private var renderPresentation: CapturePresentationSnapshot {
        programSources == nil ? bakedProgramPresentation(from: presentation) : presentation
    }

    private func bakedProgramPresentation(
        from presentation: CapturePresentationSnapshot
    ) -> CapturePresentationSnapshot {
        var output = CapturePresentationSnapshot.default
        output.name = presentation.name
        output.canvas = presentation.canvas
        output.screen = SourcePlacementSnapshot(
            centerX: 0.5,
            centerY: 0.5,
            width: 1,
            height: 1,
            shape: .rectangle
        )
        output.camera.isVisible = false
        output.framing = ScreenFramingSnapshot(mode: .fullDisplay)
        return output
    }
}
