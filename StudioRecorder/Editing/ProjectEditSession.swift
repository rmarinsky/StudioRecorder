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
    private struct EditHistoryState: Equatable {
        let timeline: ProjectEditTimeline
        let sceneTimeline: StudioSceneTimeline?
        let audioAdjustment: ProjectAudioAdjustment
        let sourceAudioAdjustments: [ProjectAudioSourceAdjustment]
        let segmentAudioAdjustments: [ProjectSegmentAudioAdjustment]
    }

    let player = AVPlayer()
    @Published private(set) var proposalPlayer: AVPlayer?

    @Published private(set) var timeline: ProjectEditTimeline?
    @Published private(set) var presentation = CapturePresentationSnapshot.default
    @Published private(set) var privacyOverlays: [ProjectPrivacyOverlay] = []
    @Published private(set) var sceneTimeline: StudioSceneTimeline?
    @Published private(set) var audioAdjustment = ProjectAudioAdjustment.unchanged
    @Published private(set) var sourceAudioAdjustments: [ProjectAudioSourceAdjustment] = []
    @Published private(set) var segmentAudioAdjustments: [ProjectSegmentAudioAdjustment] = []
    @Published private(set) var audioWaveform: ProjectAudioWaveform?
    @Published private(set) var sourceAudioWaveforms: [ProjectAudioSource: ProjectAudioWaveform] = [:]
    @Published private(set) var sourceAudioWaveformErrors: [ProjectAudioSource: String] = [:]
    @Published private(set) var isLoadingAudioWaveform = false
    @Published private(set) var audioWaveformError: String?
    @Published private(set) var silenceCandidates: [Range<TimeInterval>] = []
    @Published private(set) var isDetectingSilence = false
    @Published private(set) var silenceError: String?
    @Published var selectedSegmentID: UUID?
    @Published var selectedPrivacyOverlayID: UUID?
    @Published var selectedManualZoomTransitionIndex: Int?
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?

    private let store: ProjectEditStore
    private let renderer: ProjectEditRenderer
    private let programRenderer: ProjectProgramRenderer
    private let audioWaveformAnalyzer: ProjectAudioWaveformAnalyzer
    private var document: ProjectEditDocument?
    private var projectRootURL: URL?
    private var sourceURL: URL?
    private var programSources: ProjectProgramSources?
    private var undoStack: [EditHistoryState] = []
    private var redoStack: [EditHistoryState] = []
    private var audioAdjustmentGestureStart: EditHistoryState?
    private var documentSaveTask: Task<Void, Never>?
    private var presentationRenderTask: Task<Void, Never>?
    private var audioWaveformTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private var silenceWaveform: ProjectAudioWaveform?
    private var documentRevision = 0
    private var loadID = UUID()
    private var proposalPreviewID = UUID()

    init(
        store: ProjectEditStore = ProjectEditStore(),
        renderer: ProjectEditRenderer = ProjectEditRenderer(),
        programRenderer: ProjectProgramRenderer = ProjectProgramRenderer(),
        audioWaveformAnalyzer: ProjectAudioWaveformAnalyzer = ProjectAudioWaveformAnalyzer()
    ) {
        self.store = store
        self.renderer = renderer
        self.programRenderer = programRenderer
        self.audioWaveformAnalyzer = audioWaveformAnalyzer
    }

    var canUndo: Bool { !undoStack.isEmpty && !isWorking }
    var canRedo: Bool { !redoStack.isEmpty && !isWorking }
    var canPersistEdits: Bool { document != nil }
    var editRevision: Int { documentRevision }
    var canDeleteSelectedSegment: Bool {
        guard let timeline, let selectedSegmentID else { return false }
        return timeline.segments.count > 1 && timeline.segments.contains { $0.id == selectedSegmentID }
    }
    var isEdited: Bool {
        timeline?.isIdentity == false ||
            !privacyOverlays.isEmpty ||
            sceneTimeline != programSources?.sceneTimeline ||
            !audioAdjustment.isUnchanged ||
            !sourceAudioAdjustments.isEmpty ||
            !segmentAudioAdjustments.isEmpty
    }
    var canEditPrivacy: Bool { canPersistEdits && timeline != nil }
    var canEditManualZoom: Bool { canPersistEdits && timeline != nil && sceneTimeline != nil }
    var canEditRecordedScenes: Bool { canPersistEdits && timeline != nil && programSources != nil }
    var capturedDisplayIDs: [UInt32] {
        programSources?.screenSources.compactMap(\.displayID) ?? []
    }
    var hasCapturedCamera: Bool { programSources?.cameraURL != nil }
    func importScenePNG(from sourceURL: URL, canvas: CaptureCanvasSnapshot) throws -> ImageOverlaySnapshot {
        guard let projectRootURL, canEditRecordedScenes else {
            throw StudioSceneEditError.unavailableSource
        }
        return try ImageOverlayImporter.importPNG(
            from: sourceURL,
            canvas: canvas,
            destinationDirectory: projectRootURL.appending(path: "overlays", directoryHint: .isDirectory)
        )
    }
    var availableAudioSources: [ProjectAudioSource] { programSources?.audioSourceOrder ?? [] }
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
        dismissProposalPreview()
        isLoading = true
        documentRevision += 1
        documentSaveTask?.cancel()
        documentSaveTask = nil
        presentationRenderTask?.cancel()
        presentationRenderTask = nil
        audioWaveformTask?.cancel()
        audioWaveformTask = nil
        silenceTask?.cancel()
        silenceTask = nil
        silenceWaveform = nil
        silenceCandidates = []
        silenceError = nil
        isDetectingSilence = false
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
        audioAdjustment = .unchanged
        sourceAudioAdjustments = []
        segmentAudioAdjustments = []
        audioWaveform = nil
        sourceAudioWaveforms = [:]
        sourceAudioWaveformErrors = [:]
        isLoadingAudioWaveform = false
        audioWaveformError = nil
        document = nil
        selectedSegmentID = nil
        selectedPrivacyOverlayID = nil
        selectedManualZoomTransitionIndex = nil
        undoStack = []
        redoStack = []
        audioAdjustmentGestureStart = nil
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
                if let staleTimeline = editDocument.timeline(for: track.id) {
                    let staleSegmentIDs = Set(staleTimeline.segments.map(\.id))
                    editDocument.segmentAudioAdjustments.removeAll {
                        staleSegmentIDs.contains($0.segmentID)
                    }
                }
                editTimeline = try ProjectEditTimeline(trackID: track.id, sourceDuration: duration)
                editDocument.replaceTimeline(editTimeline)
            }
            sceneTimeline = loadedSceneTimeline
            audioAdjustment = editDocument.audioAdjustment
            sourceAudioAdjustments = editDocument.sourceAudioAdjustments.filter {
                programSources?.audioSourceOrder.contains($0.source) == true
            }
            let editSegmentIDs = Set(editTimeline.segments.map(\.id))
            segmentAudioAdjustments = editDocument.segmentAudioAdjustments.filter {
                editSegmentIDs.contains($0.segmentID)
            }
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
            loadAudioWaveform(
                from: programSources?.audioURL ?? sourceURL,
                sourceOrder: programSources?.audioSourceOrder ?? [],
                sourceTrackIDs: programSources?.audioSourceTrackIDs ?? [:],
                projectRootURL: projectRootURL,
                requestID: requestID
            )
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
        let inheritedAdjustment = current.segment(at: playhead)
            .map { segmentAudioAdjustment(for: $0.id) }
        var next = current
        do {
            try next.split(at: playhead, newSegmentID: newSegmentID)
            var nextAdjustments = segmentAudioAdjustments
            if let inheritedAdjustment, !inheritedAdjustment.isUnchanged {
                nextAdjustments.append(ProjectSegmentAudioAdjustment(
                    segmentID: newSegmentID,
                    gain: inheritedAdjustment.gain,
                    isMuted: inheritedAdjustment.isMuted
                ))
            }
            await commitEdit(
                next,
                segmentAudioAdjustments: nextAdjustments,
                selectedSegmentID: newSegmentID,
                seekTime: playhead
            )
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

    func moveSelectedSegment(by offset: Int) async {
        guard let current = timeline,
              let selectedSegmentID,
              let index = current.segments.firstIndex(where: { $0.id == selectedSegmentID }),
              current.segments.indices.contains(index + offset) else { return }
        var next = current
        do {
            try next.move(segmentID: selectedSegmentID, toIndex: index + offset)
            let seekTime = next.segments.prefix(index + offset).reduce(0) { $0 + $1.duration }
            await commitEdit(next, selectedSegmentID: selectedSegmentID, seekTime: seekTime)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveOutputRange(_ range: Range<TimeInterval>, before destination: TimeInterval) async {
        guard let current = timeline else { return }
        var next = current
        do {
            let splitParents = try next.move(range: range, before: destination)
            guard next != current else { return }
            var nextAdjustments = segmentAudioAdjustments
            for (newID, parentID) in splitParents {
                let inherited = segmentAudioAdjustment(for: parentID)
                if !inherited.isUnchanged {
                    nextAdjustments.append(ProjectSegmentAudioAdjustment(
                        segmentID: newID, gain: inherited.gain, isMuted: inherited.isMuted
                    ))
                }
            }
            let movedStart = destination > range.upperBound
                ? destination - (range.upperBound - range.lowerBound)
                : destination
            await commitEdit(
                next, segmentAudioAdjustments: nextAdjustments,
                selectedSegmentID: next.segment(at: movedStart)?.id,
                seekTime: movedStart
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteOutputRange(_ range: Range<TimeInterval>) async {
        guard let current = timeline else { return }
        var next = current
        do {
            try next.delete(range: range)
            let seekTime = min(range.lowerBound, next.duration)
            await commitEdit(
                next,
                selectedSegmentID: next.segment(at: seekTime)?.id ?? next.segments.last?.id,
                seekTime: seekTime
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteOutputRanges(_ ranges: [Range<TimeInterval>]) async {
        guard let current = timeline, !ranges.isEmpty else { return }
        var next = current
        do {
            try next.delete(ranges: ranges)
            let seekTime = min(ranges.map(\.lowerBound).min() ?? 0, next.duration)
            await commitEdit(
                next,
                selectedSegmentID: next.segment(at: seekTime)?.id ?? next.segments.last?.id,
                seekTime: seekTime
            )
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
            if errorMessage == nil, !audioAdjustment.isUnchanged {
                updateAudioAdjustment(.unchanged)
            }
            if errorMessage == nil, !sourceAudioAdjustments.isEmpty {
                clearSourceAudioAdjustments()
            }
            if errorMessage == nil, !segmentAudioAdjustments.isEmpty {
                clearCurrentTimelineSegmentAudioAdjustments()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func undo() async {
        guard let current = currentHistoryState, let previous = undoStack.last else { return }
        await commit(
            previous,
            selectedSegmentID: previous.timeline.segments.first?.id,
            seekTime: 0,
            nextUndoStack: Array(undoStack.dropLast()),
            nextRedoStack: redoStack + [current]
        )
    }

    func redo() async {
        guard let current = currentHistoryState, let next = redoStack.last else { return }
        await commit(
            next,
            selectedSegmentID: next.timeline.segments.first?.id,
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
                audioAdjustment: audioAdjustment,
                sourceAudioAdjustments: sourceAudioAdjustments,
                segmentAudioAdjustments: segmentAudioAdjustments,
                to: destinationURL
            )
        } else {
            try await renderer.exportMovie(
                from: sourceURL,
                timeline: timeline,
                audioAdjustment: audioAdjustment,
                segmentAudioAdjustments: segmentAudioAdjustments,
                to: destinationURL
            )
        }
    }

    func makeExportRecipe(to destinationURL: URL) throws -> ProjectExportRecipe {
        guard let sourceURL, let timeline, let document else {
            throw ProjectEditRendererError.unreadableSource
        }
        return ProjectExportRecipe(
            projectID: document.projectID,
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            timeline: timeline,
            presentation: renderPresentation,
            programSources: renderSources(for: sourceURL),
            editRevision: document.updatedAt,
            privacyOverlays: privacyOverlays,
            audioAdjustment: audioAdjustment,
            sourceAudioAdjustments: sourceAudioAdjustments,
            segmentAudioAdjustments: segmentAudioAdjustments
        )
    }

    func detectSilence() {
        guard let timeline, let sourceURL, let projectRootURL else { return }
        silenceTask?.cancel()
        isDetectingSilence = true
        silenceError = nil
        let operationID = loadID
        let audioURL = programSources?.audioURL ?? sourceURL
        let buckets = Int(min(ceil(timeline.sourceDuration / 0.02), 200_000))
        silenceTask = Task(priority: .background) { [weak self, audioWaveformAnalyzer] in
            do {
                let waveform = try await audioWaveformAnalyzer.waveform(
                    for: audioURL,
                    cacheURL: projectRootURL.appending(path: "analysis/silence-waveform.json"),
                    bucketCount: buckets
                )
                try Task.checkCancellation()
                guard let self, self.loadID == operationID, let current = self.timeline else { return }
                self.silenceWaveform = waveform
                self.silenceCandidates = ProjectSilenceDetector.candidates(in: waveform, timeline: current)
                self.isDetectingSilence = false
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.loadID == operationID else { return }
                self.silenceError = error.localizedDescription
                self.isDetectingSilence = false
            }
        }
    }

    func updateAudioAdjustment(_ next: ProjectAudioAdjustment) {
        guard !isWorking, var nextDocument = document, let projectRootURL else { return }
        let validated = ProjectAudioAdjustment(gain: next.gain, isMuted: next.isMuted)
        guard validated != audioAdjustment else { return }
        pushAudioHistoryUnlessDragging()
        audioAdjustment = validated
        nextDocument.replaceAudioAdjustment(validated)
        document = nextDocument
        scheduleDocumentSave(in: projectRootURL)
        scheduleProgramRefresh(force: true)
    }

    func sourceAudioAdjustment(for source: ProjectAudioSource) -> ProjectAudioSourceAdjustment {
        sourceAudioAdjustments.first { $0.source == source }
            ?? ProjectAudioSourceAdjustment(source: source)
    }

    func updateSourceAudioAdjustment(_ next: ProjectAudioSourceAdjustment) {
        guard !isWorking,
              availableAudioSources.contains(next.source),
              var nextDocument = document,
              let projectRootURL else { return }
        let validated = ProjectAudioSourceAdjustment(
            source: next.source,
            gain: next.gain,
            isMuted: next.isMuted
        )
        guard validated != sourceAudioAdjustment(for: next.source) else { return }
        pushAudioHistoryUnlessDragging()
        nextDocument.replaceSourceAudioAdjustment(validated)
        sourceAudioAdjustments.removeAll { $0.source == validated.source }
        if !validated.isUnchanged { sourceAudioAdjustments.append(validated) }
        document = nextDocument
        scheduleDocumentSave(in: projectRootURL)
        scheduleProgramRefresh(force: true)
    }

    private func clearSourceAudioAdjustments() {
        guard var nextDocument = document, let projectRootURL else { return }
        pushAudioHistoryUnlessDragging()
        nextDocument.sourceAudioAdjustments = []
        nextDocument.updatedAt = Date()
        sourceAudioAdjustments = []
        document = nextDocument
        scheduleDocumentSave(in: projectRootURL)
        scheduleProgramRefresh(force: true)
    }

    func segmentAudioAdjustment(for segmentID: UUID) -> ProjectSegmentAudioAdjustment {
        segmentAudioAdjustments.first { $0.segmentID == segmentID }
            ?? ProjectSegmentAudioAdjustment(segmentID: segmentID)
    }

    func updateSegmentAudioAdjustment(_ next: ProjectSegmentAudioAdjustment) {
        guard !isWorking,
              timeline?.segments.contains(where: { $0.id == next.segmentID }) == true,
              var nextDocument = document,
              let projectRootURL else { return }
        let validated = ProjectSegmentAudioAdjustment(
            segmentID: next.segmentID,
            gain: next.gain,
            isMuted: next.isMuted
        )
        guard validated != segmentAudioAdjustment(for: next.segmentID) else { return }
        pushAudioHistoryUnlessDragging()
        nextDocument.replaceSegmentAudioAdjustment(validated)
        segmentAudioAdjustments.removeAll { $0.segmentID == validated.segmentID }
        if !validated.isUnchanged { segmentAudioAdjustments.append(validated) }
        document = nextDocument
        scheduleDocumentSave(in: projectRootURL)
        scheduleProgramRefresh(force: true)
    }

    private func clearCurrentTimelineSegmentAudioAdjustments() {
        guard let timeline, var nextDocument = document, let projectRootURL else { return }
        pushCurrentHistoryState()
        let currentSegmentIDs = Set(timeline.segments.map(\.id))
        nextDocument.segmentAudioAdjustments.removeAll { currentSegmentIDs.contains($0.segmentID) }
        nextDocument.updatedAt = Date()
        segmentAudioAdjustments = []
        document = nextDocument
        scheduleDocumentSave(in: projectRootURL)
        scheduleProgramRefresh(force: true)
    }

    func beginAudioAdjustmentGesture() {
        guard audioAdjustmentGestureStart == nil else { return }
        audioAdjustmentGestureStart = currentHistoryState
    }

    func endAudioAdjustmentGesture() {
        guard let start = audioAdjustmentGestureStart else { return }
        audioAdjustmentGestureStart = nil
        guard currentHistoryState != start else { return }
        objectWillChange.send()
        undoStack.append(start)
        redoStack = []
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

    func scenePresentation(for outputRange: Range<TimeInterval>) -> CapturePresentationSnapshot? {
        guard let timeline,
              let sourceRange = try? timeline.sourceRange(for: outputRange) else { return nil }
        return sceneTimeline?.presentation(at: sourceRange.lowerBound) ?? presentation
    }

    func sceneDisplayID(for outputRange: Range<TimeInterval>) -> UInt32? {
        guard let timeline,
              let sourceRange = try? timeline.sourceRange(for: outputRange) else { return nil }
        return sceneTimeline?.displayID(at: sourceRange.lowerBound)
            ?? programSources?.screenDisplayID
            ?? programSources?.screenSources.first?.displayID
    }

    func canApplyScene(
        to outputRange: Range<TimeInterval>,
        presentation nextPresentation: CapturePresentationSnapshot,
        displayID: UInt32?
    ) async -> Bool {
        guard canEditRecordedScenes, let timeline, let programSources,
              let sourceRange = try? timeline.sourceRange(for: outputRange),
              nextPresentation.screen.isVisible || nextPresentation.camera.isVisible else { return false }
        do {
            if nextPresentation.screen.isVisible {
                let screenSource = displayID.flatMap { id in
                    programSources.screenSources.first { $0.displayID == id }
                } ?? (displayID == nil ? programSources.screenSources.first : nil)
                guard let screenSource,
                      try await containsVideo(in: screenSource.url, throughout: sourceRange) else {
                    return false
                }
            }
            if nextPresentation.camera.isVisible {
                guard let cameraURL = programSources.cameraURL,
                      try await containsVideo(
                        in: cameraURL,
                        throughout: (sourceRange.lowerBound - programSources.cameraTimeOffset)..<(sourceRange.upperBound - programSources.cameraTimeOffset)
                      ) else { return false }
            }
            return true
        } catch { return false }
    }

    func applyScene(
        to outputRange: Range<TimeInterval>,
        presentation nextPresentation: CapturePresentationSnapshot,
        displayID: UInt32?,
        transition: StudioSceneTransitionConfiguration
    ) async {
        guard !isWorking, let timeline, let programSources else { return }
        let operationID = loadID
        errorMessage = nil
        do {
            let sourceRange = try timeline.sourceRange(for: outputRange)
            guard await canApplyScene(
                to: outputRange, presentation: nextPresentation, displayID: displayID
            ) else {
                throw StudioSceneEditError.unavailableSource
            }
            var nextScenes = sceneTimeline ?? StudioSceneTimeline(
                initialPresentation: presentation,
                displayID: programSources.screenDisplayID
            )
            try nextScenes.overrideScene(
                in: sourceRange, sourceDuration: timeline.sourceDuration,
                with: nextPresentation, displayID: displayID ?? programSources.screenDisplayID,
                transition: transition
            )
            guard loadID == operationID else { return }
            guard let current = currentHistoryState else { return }
            await commit(
                EditHistoryState(
                    timeline: timeline, sceneTimeline: nextScenes,
                    audioAdjustment: audioAdjustment,
                    sourceAudioAdjustments: sourceAudioAdjustments,
                    segmentAudioAdjustments: segmentAudioAdjustments
                ),
                selectedSegmentID: selectedSegmentID,
                seekTime: outputRange.lowerBound,
                nextUndoStack: undoStack + [current],
                nextRedoStack: []
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func previewProposal(timeline candidate: ProjectEditTimeline, at seekTime: TimeInterval) async {
        guard let timeline, candidate.trackID == timeline.trackID,
              candidate.sourceDuration == timeline.sourceDuration else { return }
        await preview(
            timeline: candidate, sceneTimelineOverride: nil,
            segmentAudioAdjustments: segmentAudioAdjustments, at: seekTime
        )
    }

    func previewMove(_ range: Range<TimeInterval>, before destination: TimeInterval) async {
        guard let timeline else { return }
        var candidate = timeline
        do {
            let splitParents = try candidate.move(range: range, before: destination)
            var adjustments = segmentAudioAdjustments
            for (newID, parentID) in splitParents {
                let inherited = segmentAudioAdjustment(for: parentID)
                if !inherited.isUnchanged {
                    adjustments.append(ProjectSegmentAudioAdjustment(
                        segmentID: newID, gain: inherited.gain, isMuted: inherited.isMuted
                    ))
                }
            }
            let movedStart = destination > range.upperBound
                ? destination - (range.upperBound - range.lowerBound) : destination
            await preview(
                timeline: candidate, sceneTimelineOverride: nil,
                segmentAudioAdjustments: adjustments, at: movedStart
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func previewScene(
        to outputRange: Range<TimeInterval>,
        presentation nextPresentation: CapturePresentationSnapshot,
        displayID: UInt32?,
        transition: StudioSceneTransitionConfiguration
    ) async {
        guard let timeline, let programSources else { return }
        let operationID = loadID
        let revision = documentRevision
        do {
            let sourceRange = try timeline.sourceRange(for: outputRange)
            guard await canApplyScene(
                to: outputRange, presentation: nextPresentation, displayID: displayID
            ) else { throw StudioSceneEditError.unavailableSource }
            guard loadID == operationID, documentRevision == revision else { return }
            var nextScenes = sceneTimeline ?? StudioSceneTimeline(
                initialPresentation: presentation, displayID: programSources.screenDisplayID
            )
            try nextScenes.overrideScene(
                in: sourceRange, sourceDuration: timeline.sourceDuration,
                with: nextPresentation, displayID: displayID ?? programSources.screenDisplayID,
                transition: transition
            )
            await preview(
                timeline: timeline, sceneTimelineOverride: .some(nextScenes),
                segmentAudioAdjustments: segmentAudioAdjustments, at: outputRange.lowerBound
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissProposalPreview() {
        proposalPreviewID = UUID()
        proposalPlayer?.pause()
        proposalPlayer = nil
    }

    private func preview(
        timeline candidate: ProjectEditTimeline,
        sceneTimelineOverride: StudioSceneTimeline??,
        segmentAudioAdjustments: [ProjectSegmentAudioAdjustment],
        at seekTime: TimeInterval
    ) async {
        guard !isWorking, let sourceURL, document != nil else { return }
        dismissProposalPreview()
        let previewID = proposalPreviewID
        let operationID = loadID
        let revision = documentRevision
        errorMessage = nil
        do {
            let item = try await makePlayerItem(
                sourceURL: sourceURL, timeline: candidate, presentation: presentation,
                privacyOverlays: privacyOverlays,
                sceneTimelineOverride: sceneTimelineOverride,
                segmentAudioAdjustments: segmentAudioAdjustments
            )
            guard proposalPreviewID == previewID, loadID == operationID,
                  documentRevision == revision, !Task.isCancelled else { return }
            let previewPlayer = AVPlayer(playerItem: item)
            let safeSeek = min(max(seekTime, 0), max(candidate.duration - 0.001, 0))
            await previewPlayer.seek(to: CMTime(seconds: safeSeek, preferredTimescale: 600))
            guard proposalPreviewID == previewID, loadID == operationID,
                  documentRevision == revision, !Task.isCancelled else { return }
            player.pause()
            proposalPlayer = previewPlayer
        } catch {
            guard proposalPreviewID == previewID else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func containsVideo(in url: URL, throughout range: Range<TimeInterval>) async throws -> Bool {
        guard range.lowerBound >= -0.02, range.upperBound > range.lowerBound else { return false }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        return duration.isFinite && range.upperBound <= duration + 0.02
            && !tracks.isEmpty
    }

    func prepareMediaForDerivedExport() async throws -> PreparedProjectMedia {
        guard let sourceURL else { throw ProjectEditRendererError.unreadableSource }
        guard let timeline else {
            return PreparedProjectMedia(url: sourceURL, isTemporary: false)
        }
        guard !timeline.isIdentity || programSources != nil || !privacyOverlays.isEmpty
                || !audioAdjustment.isUnchanged || !sourceAudioAdjustments.isEmpty
                || !segmentAudioAdjustments.isEmpty else {
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
                audioAdjustment: audioAdjustment,
                sourceAudioAdjustments: sourceAudioAdjustments,
                segmentAudioAdjustments: segmentAudioAdjustments,
                to: outputURL
            )
        } else {
            try await renderer.exportMovie(
                from: sourceURL,
                timeline: timeline,
                audioAdjustment: audioAdjustment,
                segmentAudioAdjustments: segmentAudioAdjustments,
                to: outputURL
            )
        }
        return PreparedProjectMedia(url: outputURL, isTemporary: true)
    }

    func stop() {
        loadID = UUID()
        documentRevision += 1
        dismissProposalPreview()
        player.pause()
        documentSaveTask?.cancel()
        presentationRenderTask?.cancel()
        audioWaveformTask?.cancel()
        silenceTask?.cancel()
        isLoadingAudioWaveform = false
        isDetectingSilence = false
        audioAdjustmentGestureStart = nil
        if let document, let projectRootURL {
            documentSaveTask = Task { [store] in
                try? await store.save(document, in: projectRootURL)
            }
        }
    }

    private func commitEdit(
        _ next: ProjectEditTimeline,
        segmentAudioAdjustments nextSegmentAudioAdjustments: [ProjectSegmentAudioAdjustment]? = nil,
        selectedSegmentID: UUID?,
        seekTime: TimeInterval
    ) async {
        guard let current = currentHistoryState else { return }
        await commit(
            EditHistoryState(
                timeline: next,
                sceneTimeline: sceneTimeline,
                audioAdjustment: audioAdjustment,
                sourceAudioAdjustments: sourceAudioAdjustments,
                segmentAudioAdjustments: nextSegmentAudioAdjustments ?? segmentAudioAdjustments
            ),
            selectedSegmentID: selectedSegmentID,
            seekTime: seekTime,
            nextUndoStack: undoStack + [current],
            nextRedoStack: []
        )
    }

    private func commit(
        _ next: EditHistoryState,
        selectedSegmentID: UUID?,
        seekTime: TimeInterval,
        nextUndoStack: [EditHistoryState],
        nextRedoStack: [EditHistoryState]
    ) async {
        guard !isWorking,
              let sourceURL,
              let projectRootURL,
              document != nil else { return }
        dismissProposalPreview()
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
                timeline: next.timeline,
                presentation: presentation,
                privacyOverlays: privacyOverlays,
                sceneTimelineOverride: .some(next.sceneTimeline),
                audioAdjustment: next.audioAdjustment,
                sourceAudioAdjustments: next.sourceAudioAdjustments,
                segmentAudioAdjustments: next.segmentAudioAdjustments
            )
            guard loadID == operationID, var nextDocument = document else { return }
            let previousSegmentIDs = Set(
                nextDocument.timeline(for: next.timeline.trackID)?.segments.map(\.id) ?? []
            )
            nextDocument.replaceTimeline(next.timeline)
            nextDocument.replaceSceneTimeline(next.sceneTimeline)
            nextDocument.replaceAudioAdjustment(next.audioAdjustment)
            nextDocument.sourceAudioAdjustments = next.sourceAudioAdjustments
            nextDocument.segmentAudioAdjustments.removeAll {
                previousSegmentIDs.contains($0.segmentID)
            }
            nextDocument.segmentAudioAdjustments.append(contentsOf: next.segmentAudioAdjustments)
            let allSegmentIDs = Set(nextDocument.timelines.flatMap { $0.segments.map(\.id) })
            nextDocument.retainSegmentAudioAdjustments(for: allSegmentIDs)
            try await store.save(nextDocument, in: projectRootURL)
            guard loadID == operationID else { return }
            document = nextDocument
            documentRevision += 1
            timeline = next.timeline
            if let silenceWaveform {
                silenceCandidates = ProjectSilenceDetector.candidates(
                    in: silenceWaveform, timeline: next.timeline
                )
            }
            sceneTimeline = next.sceneTimeline
            audioAdjustment = next.audioAdjustment
            sourceAudioAdjustments = next.sourceAudioAdjustments
            let nextSegmentIDs = Set(next.timeline.segments.map(\.id))
            segmentAudioAdjustments = next.segmentAudioAdjustments.filter {
                nextSegmentIDs.contains($0.segmentID)
            }
            self.selectedSegmentID = selectedSegmentID
            undoStack = nextUndoStack
            redoStack = nextRedoStack
            player.replaceCurrentItem(with: item)
            let safeSeekTime = min(max(seekTime, 0), max(next.timeline.duration - 0.001, 0))
            await player.seek(to: CMTime(seconds: safeSeekTime, preferredTimescale: 600))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func makePlayerItem(
        sourceURL: URL,
        timeline: ProjectEditTimeline,
        presentation: CapturePresentationSnapshot,
        privacyOverlays: [ProjectPrivacyOverlay],
        sceneTimelineOverride: StudioSceneTimeline?? = nil,
        audioAdjustment: ProjectAudioAdjustment? = nil,
        sourceAudioAdjustments: [ProjectAudioSourceAdjustment]? = nil,
        segmentAudioAdjustments: [ProjectSegmentAudioAdjustment]? = nil
    ) async throws -> AVPlayerItem {
        let audioAdjustment = audioAdjustment ?? self.audioAdjustment
        let sourceAudioAdjustments = sourceAudioAdjustments ?? self.sourceAudioAdjustments
        let segmentAudioAdjustments = segmentAudioAdjustments ?? self.segmentAudioAdjustments
        if let renderSources = renderSources(
            for: sourceURL,
            privacyOverlays: privacyOverlays,
            sceneTimelineOverride: sceneTimelineOverride
        ) {
            return try await programRenderer.makePlayerItem(
                sources: renderSources,
                timeline: timeline,
                presentation: programSources == nil ? bakedProgramPresentation(from: presentation) : presentation,
                privacyOverlays: privacyOverlays,
                audioAdjustment: audioAdjustment,
                sourceAudioAdjustments: sourceAudioAdjustments,
                segmentAudioAdjustments: segmentAudioAdjustments
            )
        }
        return try await renderer.makePlayerItem(
            from: sourceURL,
            timeline: timeline,
            audioAdjustment: audioAdjustment,
            segmentAudioAdjustments: segmentAudioAdjustments
        )
    }

    private var currentHistoryState: EditHistoryState? {
        timeline.map {
            EditHistoryState(
                timeline: $0,
                sceneTimeline: sceneTimeline,
                audioAdjustment: audioAdjustment,
                sourceAudioAdjustments: sourceAudioAdjustments,
                segmentAudioAdjustments: segmentAudioAdjustments
            )
        }
    }

    private func pushCurrentHistoryState() {
        guard let currentHistoryState else { return }
        undoStack.append(currentHistoryState)
        redoStack = []
    }

    private func pushAudioHistoryUnlessDragging() {
        guard audioAdjustmentGestureStart == nil else { return }
        pushCurrentHistoryState()
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

    private func loadAudioWaveform(
        from audioURL: URL,
        sourceOrder: [ProjectAudioSource],
        sourceTrackIDs: [CMPersistentTrackID: ProjectAudioSource],
        projectRootURL: URL,
        requestID: UUID
    ) {
        audioWaveformTask?.cancel()
        audioWaveform = nil
        sourceAudioWaveforms = [:]
        sourceAudioWaveformErrors = [:]
        audioWaveformError = nil
        isLoadingAudioWaveform = true
        audioWaveformTask = Task { [weak self, audioWaveformAnalyzer] in
            do {
                let analysisDirectory = projectRootURL
                    .appending(path: "analysis", directoryHint: .isDirectory)
                if sourceOrder.isEmpty {
                    let waveform = try await audioWaveformAnalyzer.waveform(
                        for: audioURL,
                        cacheURL: analysisDirectory.appending(path: "audio-waveform.json")
                    )
                    try Task.checkCancellation()
                    guard let self, self.loadID == requestID else { return }
                    self.audioWaveform = waveform
                } else {
                    var waveforms: [ProjectAudioSource: ProjectAudioWaveform] = [:]
                    var errors: [ProjectAudioSource: String] = [:]
                    for (index, source) in sourceOrder.enumerated() {
                        let persistentTrackID = sourceTrackIDs.first { $0.value == source }?.key
                        do {
                            waveforms[source] = try await audioWaveformAnalyzer.waveform(
                                for: audioURL,
                                cacheURL: analysisDirectory.appending(path: "audio-waveform-\(source.rawValue).json"),
                                trackIndex: persistentTrackID == nil ? index : nil,
                                persistentTrackID: persistentTrackID
                            )
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            errors[source] = error.localizedDescription
                        }
                    }
                    try Task.checkCancellation()
                    guard let self, self.loadID == requestID else { return }
                    self.sourceAudioWaveforms = waveforms
                    self.sourceAudioWaveformErrors = errors
                }
                self?.isLoadingAudioWaveform = false
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.loadID == requestID else { return }
                self.audioWaveformError = error.localizedDescription
                self.isLoadingAudioWaveform = false
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
        dismissProposalPreview()
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
            documentRevision += 1
            privacyOverlays = next
            selectedPrivacyOverlayID = selectedID
            player.replaceCurrentItem(with: item)
            await player.seek(to: CMTime(seconds: seekTime, preferredTimescale: 600))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleDocumentSave(in projectRootURL: URL) {
        dismissProposalPreview()
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
        privacyOverlays: [ProjectPrivacyOverlay]? = nil,
        sceneTimelineOverride: StudioSceneTimeline?? = nil
    ) -> ProjectProgramSources? {
        if let programSources {
            return programSources.replacingSceneTimeline(sceneTimelineOverride ?? sceneTimeline)
        }
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
