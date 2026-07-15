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
    @Published var selectedSegmentID: UUID?
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?

    private let store: ProjectEditStore
    private let renderer: ProjectEditRenderer
    private var document: ProjectEditDocument?
    private var projectRootURL: URL?
    private var sourceURL: URL?
    private var undoStack: [ProjectEditTimeline] = []
    private var redoStack: [ProjectEditTimeline] = []
    private var loadID = UUID()

    init(store: ProjectEditStore = ProjectEditStore(), renderer: ProjectEditRenderer = ProjectEditRenderer()) {
        self.store = store
        self.renderer = renderer
    }

    var canUndo: Bool { !undoStack.isEmpty && !isWorking }
    var canRedo: Bool { !redoStack.isEmpty && !isWorking }
    var canDeleteSelectedSegment: Bool {
        guard let timeline, let selectedSegmentID else { return false }
        return timeline.segments.count > 1 && timeline.segments.contains { $0.id == selectedSegmentID }
    }
    var isEdited: Bool { timeline?.isIdentity == false }
    var playhead: TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(seconds, 0) : 0
    }

    func load(projectID: UUID?, projectRootURL: URL, track: RecordingTrackDescriptor, sourceURL: URL) async {
        let requestID = UUID()
        loadID = requestID
        player.pause()
        player.replaceCurrentItem(with: nil)
        timeline = nil
        document = nil
        selectedSegmentID = nil
        undoStack = []
        redoStack = []
        errorMessage = nil
        self.projectRootURL = projectRootURL
        self.sourceURL = sourceURL
        isLoading = true
        defer {
            if loadID == requestID { isLoading = false }
        }

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
            let editTimeline: ProjectEditTimeline
            if let saved = editDocument.timeline(for: track.id),
               abs(saved.sourceDuration - duration) < 0.1 {
                editTimeline = saved
            } else {
                editTimeline = try ProjectEditTimeline(trackID: track.id, sourceDuration: duration)
                editDocument.replaceTimeline(editTimeline)
            }
            let item = try await renderer.makePlayerItem(from: sourceURL, timeline: editTimeline)
            try Task.checkCancellation()
            guard loadID == requestID else { return }
            document = editDocument
            timeline = editTimeline
            selectedSegmentID = editTimeline.segments.first?.id
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
        do {
            let next = try ProjectEditTimeline(trackID: current.trackID, sourceDuration: current.sourceDuration)
            await commitEdit(next, selectedSegmentID: next.segments.first?.id, seekTime: 0)
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
        try await renderer.exportMovie(from: sourceURL, timeline: timeline, to: destinationURL)
    }

    func prepareMediaForDerivedExport() async throws -> PreparedProjectMedia {
        guard let sourceURL else { throw ProjectEditRendererError.unreadableSource }
        guard let timeline else {
            return PreparedProjectMedia(url: sourceURL, isTemporary: false)
        }
        guard !timeline.isIdentity else {
            return PreparedProjectMedia(url: sourceURL, isTemporary: false)
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "Studio Recorder Derived", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appending(path: "\(UUID().uuidString).mov")
        try await renderer.exportMovie(from: sourceURL, timeline: timeline, to: outputURL)
        return PreparedProjectMedia(url: outputURL, isTemporary: true)
    }

    func stop() {
        loadID = UUID()
        player.pause()
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
              var nextDocument = document else { return }
        let operationID = loadID
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            let item = try await renderer.makePlayerItem(from: sourceURL, timeline: next)
            guard loadID == operationID else { return }
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
}
