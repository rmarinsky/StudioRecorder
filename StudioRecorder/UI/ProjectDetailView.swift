import AppKit
import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct ProjectDetailView: View {
    private struct AssistantMessage: Identifiable {
        let id = UUID()
        let role: String
        let text: String
        let draft: OpenRouterAssistantDraft?
    }

    let project: RecordingProjectSnapshot
    let onClose: () -> Void
    let exportRequest: Int
    let queueExport: (ProjectExportRecipe) async throws -> Void
    let jobs: [RecordingJob]
    let queueTranscription: (ProjectTranscriptionRecipe) async throws -> Void

    @Environment(\.colorScheme) private var colorScheme

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
    @State private var isAssistantVisible = true
    @State private var isTranscriptVisible = true
    @State private var isShowingDetails = false
    @State private var selectedRange: Range<TimeInterval>?
    @State private var timelineFocusRequest: ProjectTimelineFocusRequest?
    @State private var transcript: TimedTranscript?
    @State private var transcriptSearch = ""
    @State private var transcriptWordSelection = TranscriptWordSelection()
    @State private var selectedPhraseID: String?
    @State private var expandedPhraseIDs: Set<String> = []
    @State private var transcriptError: String?
    @State private var transcriptFileUnreadable = false
    @State private var isQueuingTranscription = false
    @AppStorage("openRouter.model") private var assistantModel = OpenRouterAssistantClient.defaultModel
    @AppStorage("assistant.provider") private var assistantProviderRaw = AssistantProvider.openRouter.rawValue
    @AppStorage("assistant.ollamaModel") private var localAssistantModel = "gemma3:4b"
    @State private var assistantPrompt = ""
    @State private var assistantScope = OpenRouterAssistantScope.wholeProject
    @State private var assistantMessages: [AssistantMessage] = []
    @State private var assistantError: String?
    @State private var isAssistantWorking = false
    @State private var assistantRequestID = UUID()
    @State private var assistantTask: Task<Void, Never>?
    @FocusState private var focusedTranscriptWordID: String?
    @State private var pendingAssistantCuts: OpenRouterReviewedCuts?
    @State private var isConfirmingTranscriptWordDelete = false
    @State private var isConfirmingAssistantEstimatedCuts = false
    @State private var pendingAssistantScene: OpenRouterReviewedScene?
    @State private var pendingAssistantMove: OpenRouterReviewedMove?

    private let exporter = ProjectMediaExporter()

    private var assistantProvider: AssistantProvider {
        AssistantProvider(rawValue: assistantProviderRaw) ?? .openRouter
    }

    private var selectedAssistantModel: String {
        assistantProvider == .ollama ? localAssistantModel : assistantModel
    }

    init(
        project: RecordingProjectSnapshot,
        onClose: @escaping () -> Void,
        exportRequest: Int = 0,
        queueExport: @escaping (ProjectExportRecipe) async throws -> Void,
        jobs: [RecordingJob],
        queueTranscription: @escaping (ProjectTranscriptionRecipe) async throws -> Void
    ) {
        self.project = project
        self.onClose = onClose
        self.exportRequest = exportRequest
        self.queueExport = queueExport
        self.jobs = jobs
        self.queueTranscription = queueTranscription
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
            if let programScreenTrackURL, FileManager.default.fileExists(atPath: programScreenTrackURL.path) {
                HSplitView {
                    if isAssistantVisible {
                        assistantPanel
                            .frame(minWidth: 220, idealWidth: 300, maxWidth: .infinity)
                    }
                    editorCenter
                        .frame(minWidth: 470, idealWidth: 640, maxWidth: .infinity)
                    if isTranscriptVisible {
                        transcriptPanel
                            .frame(minWidth: 220, idealWidth: 300, maxWidth: .infinity)
                    }
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
        .onChange(of: exportRequest) { _, _ in
            if !isExporting, !editSession.isWorking, editSession.timeline != nil { exportEditedMovie() }
        }
        .task(id: programScreenTrackID) { await loadProgram() }
        .task(id: project.id) {
            loadTranscript()
            await queueMissingTranscript()
        }
        .onChange(of: editSession.timeline) { _, _ in
            Task { await queueMissingTranscript() }
        }
        .onChange(of: jobs) { _, _ in
            if transcriptionJob?.state == .completed { loadTranscript() }
        }
        .onChange(of: project.id) { _, _ in
            assistantTask?.cancel()
            assistantTask = nil
            isAssistantWorking = false
            assistantMessages = []
            assistantPrompt = ""
            assistantError = nil
            assistantRequestID = UUID()
            pendingAssistantCuts = nil
            pendingAssistantScene = nil
            pendingAssistantMove = nil
            transcriptWordSelection.clear()
        }
        .onChange(of: editSession.editRevision) { _, _ in
            pendingAssistantCuts = nil
            pendingAssistantScene = nil
            pendingAssistantMove = nil
            isConfirmingAssistantEstimatedCuts = false
        }
        .onDisappear {
            assistantTask?.cancel()
            assistantTask = nil
            isAssistantWorking = false
            assistantRequestID = UUID()
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
        .confirmationDialog("Remove selected words?", isPresented: $isConfirmingTranscriptWordDelete,
                            titleVisibility: .visible) {
            Button("Delete Selected Words", role: .destructive) {
                Task { await applyTranscriptWordDeletion() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Some selected word times are estimates. The edit will remove their video and audio intervals, which may trim nearby sound.")
        }
        .confirmationDialog("Apply cuts with estimated word times?",
                            isPresented: $isConfirmingAssistantEstimatedCuts,
                            titleVisibility: .visible) {
            Button("Apply Estimated Cuts", role: .destructive) {
                applyAssistantCuts(confirmedEstimatedTiming: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Some suggested word boundaries are uncertain and may trim nearby audio. Review the highlighted spans before continuing.")
        }
    }

    private var assistantPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Assistant").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Hide Assistant", systemImage: "sidebar.left") {
                    isAssistantVisible = false
                }
                .labelStyle(.iconOnly)
            }
            .padding(14)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if assistantMessages.isEmpty {
                        Text("Ask for cuts, phrase order, scene changes, titles, descriptions, or wording for a new take.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    Text(assistantProvider == .ollama
                         ? "Transcript and scene details go to the local Ollama service. Review every media change before applying it."
                         : "Transcript text and scene metadata are sent for the chosen scope. Review every media change before applying it.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(assistantMessages) { message in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(message.role)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(message.text)
                                .font(.caption)
                                .textSelection(.enabled)
                            if let draft = message.draft {
                                ForEach(draft.titles, id: \.self) { title in
                                    Label(title, systemImage: "textformat")
                                        .font(.caption)
                                        .textSelection(.enabled)
                                }
                                ForEach(draft.descriptions, id: \.self) { description in
                                    Text(description)
                                        .font(.caption)
                                        .textSelection(.enabled)
                                }
                                ForEach(draft.newTakeWording, id: \.self) { wording in
                                    Label(wording, systemImage: "mic")
                                        .font(.caption)
                                        .textSelection(.enabled)
                                }
                                ForEach(draft.cuts, id: \.id) { cut in
                                    Label(cut.reason, systemImage: "scissors")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                                ForEach(draft.sceneChanges, id: \.reason) { change in
                                    Label(change.reason, systemImage: "rectangle.on.rectangle")
                                        .font(.caption)
                                        .foregroundStyle(.tint)
                                }
                                ForEach(draft.phraseMoves, id: \.reason) { move in
                                    Label(move.reason, systemImage: "arrow.left.arrow.right")
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                }
                .padding(12)
            }
            Divider()
            if let pendingAssistantCuts, !pendingAssistantCuts.ranges.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(pendingAssistantCuts.ranges.count) proposed cuts")
                        .font(.caption.weight(.semibold))
                    Text(pendingAssistantCuts.requiresTimingReview
                         ? "Some word times are estimates. Red spans mark video and audio; review before applying."
                         : "Red spans mark both video and audio. Audition a span before applying.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Review") { reviewAssistantCuts() }
                        Button("Apply") { applyAssistantCuts() }
                            .disabled(editSession.isWorking || !editSession.canPersistEdits)
                        Button("Dismiss") {
                            self.pendingAssistantCuts = nil
                            editSession.dismissProposalPreview()
                        }
                    }
                    .buttonStyle(.borderless)
                    HStack {
                        Button("Refine") { assistantPrompt = "Refine the proposed cuts: " }
                        Button("Undo") { Task { await editSession.undo() } }
                            .disabled(!editSession.canUndo)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(12)
                Divider()
            }
            if let pendingAssistantScene {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Proposed scene change")
                        .font(.caption.weight(.semibold))
                    Text("\(pendingAssistantScene.change.layout.label) · \(pendingAssistantScene.change.transition.label)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(sceneChangeDetails(pendingAssistantScene.change), id: \.self) { detail in
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Review") { reviewAssistantScene() }
                        Button("Apply") { applyAssistantScene() }
                            .disabled(editSession.isWorking || !editSession.canEditRecordedScenes)
                        Button("Dismiss") {
                            self.pendingAssistantScene = nil
                            editSession.dismissProposalPreview()
                        }
                    }
                    .buttonStyle(.borderless)
                    HStack {
                        Button("Refine") { assistantPrompt = "Refine the proposed scene: " }
                        Button("Undo") { Task { await editSession.undo() } }
                            .disabled(!editSession.canUndo)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(12)
                Divider()
            }
            if let pendingAssistantMove {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Proposed phrase move")
                        .font(.caption.weight(.semibold))
                    Text(pendingAssistantMove.reason)
                        .font(.caption2)
                    Text(String(
                        format: "Move %.2f–%.2f s before %.2f s",
                        pendingAssistantMove.range.lowerBound,
                        pendingAssistantMove.range.upperBound,
                        pendingAssistantMove.destination
                    ))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    HStack {
                        Button("Review") { reviewAssistantMove() }
                        Button("Apply") { applyAssistantMove() }
                            .disabled(editSession.isWorking || !editSession.canPersistEdits)
                        Button("Dismiss") {
                            self.pendingAssistantMove = nil
                            editSession.dismissProposalPreview()
                        }
                    }
                    .buttonStyle(.borderless)
                    HStack {
                        Button("Refine") { assistantPrompt = "Refine the proposed phrase order: " }
                        Button("Undo") { Task { await editSession.undo() } }
                            .disabled(!editSession.canUndo)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(12)
                Divider()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Context")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Picker("Context", selection: $assistantScope) {
                    Text("Whole project").tag(OpenRouterAssistantScope.wholeProject)
                    Text("Selection").tag(OpenRouterAssistantScope.selection)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack {
                    Button("Find pauses") { editSession.detectSilence() }
                        .disabled(editSession.isDetectingSilence || editSession.timeline == nil)
                    if editSession.isDetectingSilence {
                        ProgressView().controlSize(.small)
                    } else if !editSession.silenceCandidates.isEmpty {
                        Text("\(editSession.silenceCandidates.count) detected")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .buttonStyle(.borderless)
                if assistantScope == .selection, selectedRange == nil {
                    Text("Select a range on the timeline first.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                TextField("Ask Assistant", text: $assistantPrompt, axis: .vertical)
                    .lineLimit(2...4)
                    .onSubmit { sendAssistantPrompt() }
                HStack {
                    Text(assistantProvider == .ollama
                         ? "Local · \(localAssistantModel)"
                         : assistantModel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button(isAssistantWorking ? "Thinking…" : "Send") { sendAssistantPrompt() }
                        .disabled(isAssistantWorking
                                  || assistantPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || (assistantScope == .selection && selectedRange == nil))
                }
                if let assistantError {
                    Text(assistantError)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(12)
            Divider()
            DisclosureGroup("Local edit tools") {
                ProjectQuickEditorView(session: editSession, onExportMovie: {}, commandsOnly: true)
            }
            .font(.caption)
            .padding(12)
        }
        .background(detailPanel)
    }

    private func sendAssistantPrompt() {
        let prompt = assistantPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isAssistantWorking,
              let projectID = project.identity.manifestID else { return }
        let scope = assistantScope
        guard scope == .wholeProject || selectedRange != nil else { return }
        let words: [OpenRouterAssistantWord] = {
            guard let transcript, let timeline = editSession.timeline else { return [] }
            return transcript.words(in: timeline)
                .filter { word in
                    guard scope == .selection, let selectedRange else { return true }
                    return word.outputStart < selectedRange.upperBound
                        && word.outputEnd > selectedRange.lowerBound
                }
                .map { OpenRouterAssistantWord(
                    id: $0.id, text: $0.text,
                    start: $0.outputStart, end: $0.outputEnd,
                    timingStatus: $0.timingStatus
                ) }
        }()
        let silences: [OpenRouterAssistantSilence] = editSession.silenceCandidates.enumerated().compactMap { index, range in
            if scope == .selection, let selectedRange,
               (range.lowerBound < selectedRange.lowerBound
                || range.upperBound > selectedRange.upperBound) { return nil }
            return OpenRouterAssistantSilence(
                id: "silence-\(index)", start: range.lowerBound, end: range.upperBound
            )
        }
        let sceneSelection: OpenRouterAssistantSceneSelection? = {
            guard scope == .selection, editSession.canEditRecordedScenes,
                  let selectedRange, let timeline = editSession.timeline,
                  (try? timeline.sourceRanges(for: selectedRange)) != nil,
                  let current = editSession.scenePresentation(for: selectedRange) else { return nil }
            return OpenRouterAssistantSceneSelection(
                start: selectedRange.lowerBound, end: selectedRange.upperBound,
                capturedDisplayIDs: editSession.capturedDisplayIDs,
                hasCapturedCamera: editSession.hasCapturedCamera,
                overlays: current.resolvedImageOverlays.map {
                    OpenRouterAssistantSceneOverlay(id: $0.id, name: $0.name)
                },
                currentState: OpenRouterAssistantSceneState(
                    screenVisible: current.screen.isVisible,
                    cameraVisible: current.camera.isVisible,
                    displayID: editSession.sceneDisplayID(for: selectedRange),
                    cameraX: current.camera.centerX,
                    cameraY: current.camera.centerY,
                    cameraWidth: current.camera.width,
                    cameraShape: current.camera.shape,
                    cameraBackground: current.resolvedCameraBackground.mode
                )
            )
        }()
        let history = assistantMessages.suffix(12).map { message in
            OpenRouterAssistantTurn(
                role: message.role == "You" ? .user : .assistant,
                content: message.text
            )
        }
        let requestID = UUID()
        assistantRequestID = requestID
        let requestTimeline = editSession.timeline
        let requestRevision = editSession.editRevision
        let requestProvider = assistantProvider
        let requestModel = selectedAssistantModel
        assistantPrompt = ""
        assistantError = nil
        assistantMessages.append(AssistantMessage(role: "You", text: prompt, draft: nil))
        isAssistantWorking = true
        assistantTask = Task {
            defer {
                if assistantRequestID == requestID {
                    isAssistantWorking = false
                    assistantTask = nil
                }
            }
            do {
                let context = OpenRouterAssistantContext(
                    projectID: projectID, scope: scope, words: words, silences: silences,
                    sceneSelection: sceneSelection
                )
                let draft: OpenRouterAssistantDraft
                switch requestProvider {
                case .openRouter:
                    guard let key = try OpenRouterAssistantKeyStore().load() else {
                        throw OpenRouterAssistantError.missingKey
                    }
                    draft = try await OpenRouterAssistantClient().draft(
                        apiKey: key, model: requestModel, prompt: prompt,
                        context: context, history: history
                    )
                case .ollama:
                    draft = try await OllamaAssistantClient().draft(
                        model: requestModel, prompt: prompt, context: context, history: history
                    )
                }
                guard assistantRequestID == requestID else { return }
                guard let requestTimeline,
                      editSession.timeline == requestTimeline,
                      editSession.editRevision == requestRevision else {
                    throw OpenRouterAssistantError.invalidProposal
                }
                let cutProposal: OpenRouterReviewedCuts? = if draft.cuts.isEmpty { nil } else {
                    try draft.reviewedCuts(
                        context: context, timeline: requestTimeline, revision: requestRevision
                    )
                }
                let sceneProposal = try draft.reviewedScene(
                    context: context, timeline: requestTimeline, revision: requestRevision
                )
                let moveProposal = try draft.reviewedMove(
                    context: context, timeline: requestTimeline, revision: requestRevision
                )
                if let sceneProposal {
                    guard let current = editSession.scenePresentation(for: sceneProposal.range),
                          await editSession.canApplyScene(
                            to: sceneProposal.range,
                            presentation: sceneProposal.change.presentation(from: current),
                            displayID: sceneProposal.change.displayID
                                ?? editSession.sceneDisplayID(for: sceneProposal.range)
                          ) else { throw OpenRouterAssistantError.invalidProposal }
                }
                guard assistantRequestID == requestID,
                      editSession.editRevision == requestRevision else { return }
                assistantMessages.append(AssistantMessage(role: "Assistant", text: draft.reply, draft: draft))
                pendingAssistantCuts = cutProposal
                pendingAssistantScene = sceneProposal
                pendingAssistantMove = moveProposal
                selectedRange = cutProposal?.ranges.first ?? sceneProposal?.range
                    ?? moveProposal?.range ?? selectedRange
            } catch {
                if assistantRequestID == requestID { assistantError = error.localizedDescription }
            }
        }
    }

    private func applyAssistantCuts(confirmedEstimatedTiming: Bool = false) {
        guard let proposal = pendingAssistantCuts,
              let projectID = project.identity.manifestID,
              let timeline = editSession.timeline,
              proposal.isCurrent(
                  projectID: projectID, timeline: timeline, revision: editSession.editRevision
              ), !proposal.ranges.isEmpty else {
            assistantError = OpenRouterAssistantError.invalidProposal.localizedDescription
            pendingAssistantCuts = nil
            return
        }
        if proposal.requiresTimingReview && !confirmedEstimatedTiming {
            isConfirmingAssistantEstimatedCuts = true
            return
        }
        Task {
            guard let current = editSession.timeline,
                  proposal.isCurrent(
                    projectID: projectID, timeline: current, revision: editSession.editRevision
                  ) else {
                assistantError = OpenRouterAssistantError.invalidProposal.localizedDescription
                pendingAssistantCuts = nil
                return
            }
            await editSession.deleteOutputRanges(proposal.ranges)
            if let error = editSession.errorMessage {
                assistantError = error
            } else {
                pendingAssistantCuts = nil
                selectedRange = nil
                transcriptWordSelection.clear()
            }
        }
    }

    private func reviewAssistantCuts() {
        guard let proposal = pendingAssistantCuts,
              let projectID = project.identity.manifestID,
              let timeline = editSession.timeline,
              proposal.isCurrent(
                projectID: projectID, timeline: timeline, revision: editSession.editRevision
              ) else {
            assistantError = OpenRouterAssistantError.invalidProposal.localizedDescription
            return
        }
        do {
            var candidate = timeline
            try candidate.delete(ranges: proposal.ranges)
            selectedRange = proposal.ranges.first
            Task {
                guard let current = editSession.timeline,
                      proposal.isCurrent(
                        projectID: projectID, timeline: current,
                        revision: editSession.editRevision
                      ) else { return }
                await editSession.previewProposal(
                    timeline: candidate,
                    at: min(proposal.ranges.first?.lowerBound ?? 0, candidate.duration)
                )
                assistantError = editSession.errorMessage
            }
        } catch {
            assistantError = error.localizedDescription
        }
    }

    private func reviewAssistantScene() {
        guard let proposal = pendingAssistantScene,
              let projectID = project.identity.manifestID,
              let timeline = editSession.timeline,
              proposal.isCurrent(
                projectID: projectID, timeline: timeline, revision: editSession.editRevision
              ), let current = editSession.scenePresentation(for: proposal.range),
              (proposal.change.overlayID.map { overlayID in
                  current.resolvedImageOverlays.contains { $0.id == overlayID }
              } ?? true) else {
            assistantError = OpenRouterAssistantError.invalidProposal.localizedDescription
            return
        }
        selectedRange = proposal.range
        Task {
            guard let latest = editSession.timeline,
                  proposal.isCurrent(
                    projectID: projectID, timeline: latest,
                    revision: editSession.editRevision
                  ) else { return }
            await editSession.previewScene(
                to: proposal.range,
                presentation: proposal.change.presentation(from: current),
                displayID: proposal.change.displayID
                    ?? editSession.sceneDisplayID(for: proposal.range),
                transition: StudioSceneTransitionConfiguration(
                    effect: proposal.change.transition, duration: proposal.change.duration
                )
            )
            assistantError = editSession.errorMessage
        }
    }

    private func reviewAssistantMove() {
        guard let proposal = pendingAssistantMove,
              let projectID = project.identity.manifestID,
              let timeline = editSession.timeline,
              proposal.isCurrent(
                projectID: projectID, timeline: timeline, revision: editSession.editRevision
              ) else {
            assistantError = OpenRouterAssistantError.invalidProposal.localizedDescription
            return
        }
        selectedRange = proposal.range
        Task {
            guard let current = editSession.timeline,
                  proposal.isCurrent(
                    projectID: projectID, timeline: current,
                    revision: editSession.editRevision
                  ) else { return }
            await editSession.previewMove(proposal.range, before: proposal.destination)
            assistantError = editSession.errorMessage
        }
    }

    private func applyAssistantScene() {
        guard let proposal = pendingAssistantScene,
              let projectID = project.identity.manifestID,
              let timeline = editSession.timeline,
              proposal.isCurrent(
                projectID: projectID, timeline: timeline, revision: editSession.editRevision
              ), let current = editSession.scenePresentation(for: proposal.range),
              (proposal.change.overlayID.map { overlayID in
                  current.resolvedImageOverlays.contains { $0.id == overlayID }
              } ?? true) else {
            assistantError = OpenRouterAssistantError.invalidProposal.localizedDescription
            pendingAssistantScene = nil
            return
        }
        Task {
            guard let timeline = editSession.timeline,
                  proposal.isCurrent(
                    projectID: projectID, timeline: timeline, revision: editSession.editRevision
                  ) else {
                assistantError = OpenRouterAssistantError.invalidProposal.localizedDescription
                pendingAssistantScene = nil
                return
            }
            await editSession.applyScene(
                to: proposal.range,
                presentation: proposal.change.presentation(from: current),
                displayID: proposal.change.displayID
                    ?? editSession.sceneDisplayID(for: proposal.range),
                transition: StudioSceneTransitionConfiguration(
                    effect: proposal.change.transition, duration: proposal.change.duration
                )
            )
            if let error = editSession.errorMessage { assistantError = error }
            else { pendingAssistantScene = nil }
        }
    }

    private func sceneChangeDetails(_ change: OpenRouterAssistantSceneChange) -> [String] {
        var details: [String] = []
        if let displayID = change.displayID { details.append("Display \(displayID)") }
        if let shape = change.cameraShape { details.append("Camera shape: \(shape.label)") }
        if let background = change.cameraBackground { details.append("Camera background: \(background.label)") }
        if change.cameraX != nil || change.cameraY != nil || change.cameraWidth != nil {
            let position = [change.cameraX, change.cameraY, change.cameraWidth]
                .map { $0.map { String(format: "%.2f", $0) } ?? "unchanged" }
                .joined(separator: ", ")
            details.append("Camera x, y, width: \(position)")
        }
        if let overlayID = change.overlayID, let visible = change.overlayVisible {
            let overlayName = pendingAssistantScene.flatMap {
                editSession.scenePresentation(for: $0.range)?.resolvedImageOverlays
                    .first(where: { $0.id == overlayID })?.name
            } ?? "Image"
            details.append("PNG \(overlayName): \(visible ? "show" : "hide")")
        }
        return details
    }

    private func applyAssistantMove() {
        guard let proposal = pendingAssistantMove,
              let projectID = project.identity.manifestID,
              let timeline = editSession.timeline,
              proposal.isCurrent(
                projectID: projectID, timeline: timeline, revision: editSession.editRevision
              ) else {
            assistantError = OpenRouterAssistantError.invalidProposal.localizedDescription
            pendingAssistantMove = nil
            return
        }
        Task {
            guard let current = editSession.timeline,
                  proposal.isCurrent(
                    projectID: projectID, timeline: current, revision: editSession.editRevision
                  ) else {
                assistantError = OpenRouterAssistantError.invalidProposal.localizedDescription
                pendingAssistantMove = nil
                return
            }
            await editSession.moveOutputRange(proposal.range, before: proposal.destination)
            if let error = editSession.errorMessage { assistantError = error }
            else {
                pendingAssistantMove = nil
                selectedRange = nil
            }
        }
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transcript").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Hide Transcript", systemImage: "sidebar.right") {
                    isTranscriptVisible = false
                }
                .labelStyle(.iconOnly)
            }
            .padding(14)
            Divider()
            if let transcript, let timeline = editSession.timeline,
               transcript.isCompatible(with: timeline) {
                TextField("Search transcript", text: $transcriptSearch)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Pauses")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(editSession.isDetectingSilence ? "Finding…" : "Find") {
                                editSession.detectSilence()
                            }
                            .disabled(editSession.isDetectingSilence || editSession.isWorking)
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 10)
                        if let silenceError = editSession.silenceError {
                            Text(silenceError).font(.caption).foregroundStyle(.orange).padding(.horizontal, 10)
                        }
                        ForEach(Array(editSession.silenceCandidates.enumerated()), id: \.offset) { _, range in
                            Button("Pause \(transcriptTime(range.lowerBound))–\(transcriptTime(range.upperBound))") {
                                transcriptWordSelection.clear()
                                selectedPhraseID = nil
                                focusTranscriptRange(range)
                            }
                            .buttonStyle(.plain)
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(selectedRange == range ? Color.accentColor.opacity(0.18) : .clear)
                        }
                        Divider().padding(.vertical, 5)
                        ForEach(visibleTranscriptPhrases) { phrase in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .top, spacing: 3) {
                                    Button {
                                        transcriptWordSelection.clear()
                                        selectedPhraseID = phrase.id
                                        focusTranscriptRange(phrase.outputRange)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(transcriptTime(phrase.outputRange.lowerBound))
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                            Text(phrase.text)
                                                .font(.caption)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .multilineTextAlignment(.leading)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Select phrase: \(phrase.text)")
                                    Button(expandedPhraseIDs.contains(phrase.id) ? "Hide Words" : "Show Words",
                                           systemImage: expandedPhraseIDs.contains(phrase.id) ? "chevron.up" : "chevron.down") {
                                        if !expandedPhraseIDs.insert(phrase.id).inserted {
                                            expandedPhraseIDs.remove(phrase.id)
                                            if phrase.words.contains(where: {
                                                transcriptWordSelection.selectedIDs.contains($0.id)
                                            }) {
                                                transcriptWordSelection.clear()
                                            }
                                        }
                                    }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.borderless)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(selectedPhraseID == phrase.id ? Color.accentColor.opacity(0.18) : .clear)
                                if expandedPhraseIDs.contains(phrase.id) {
                                    ForEach(phrase.words) { word in
                                        transcriptWordButton(word).padding(.leading, 9)
                                    }
                                }
                            }
                            Divider().padding(.leading, 10)
                        }
                    }
                    .padding(.vertical, 6)
                }
                Divider()
                if selectedTranscriptWords.count > 1,
                   let first = selectedTranscriptWords.first,
                   let last = selectedTranscriptWords.last {
                    Text("\(selectedTranscriptWords.count) words · \(transcriptTime(first.outputStart))–\(transcriptTime(last.outputEnd))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                } else if let selectedTranscriptWord {
                    Text(String(
                        format: "Output %.2f–%.2f s · Source %.2f–%.2f s",
                        selectedTranscriptWord.outputStart, selectedTranscriptWord.outputEnd,
                        selectedTranscriptWord.sourceStart, selectedTranscriptWord.sourceEnd
                    ))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                } else if let selectedRange {
                    Text("Selected \(transcriptTime(selectedRange.lowerBound))–\(transcriptTime(selectedRange.upperBound))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                }
                Button("Save Transcript…") { saveTranscriptText() }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                Text("Shift-click words to select several. Press Delete to remove their video and audio together.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                if let transcriptError {
                    Text(transcriptError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "text.alignleft")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("No timed transcript")
                        .font(.subheadline.weight(.medium))
                    Text(transcriptError ?? transcriptionStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let transcriptionJob,
                       transcriptionJob.state == .queued || transcriptionJob.state == .running {
                        ProgressView(value: transcriptionJob.progress)
                            .accessibilityLabel(transcriptionJob.stage)
                    } else if transcriptFileUnreadable {
                        Button("Reveal Project") { revealProject() }
                    } else if transcriptionJob?.state != .failed {
                        Button(isQueuingTranscription ? "Queuing…" : "Transcribe") {
                            transcriptError = nil
                            Task { await queueMissingTranscript() }
                        }
                        .disabled(isQueuingTranscription || editSession.timeline == nil)
                    }
                }
                .padding(14)
                Spacer()
            }
        }
        .background(detailPanel)
        .onDeleteCommand(perform: deleteSelectedTranscriptWords)
        .onChange(of: transcriptSearch) { _, _ in transcriptWordSelection.clear() }
    }

    private var visibleTranscriptPhrases: [EditedTranscriptPhrase] {
        guard let transcript, let timeline = editSession.timeline else { return [] }
        let phrases = transcript.phrases(in: timeline)
        let query = transcriptSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? phrases : phrases.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    private var selectedTranscriptWord: EditedTranscriptWord? {
        selectedTranscriptWords.count == 1 ? selectedTranscriptWords.first : nil
    }

    private var selectedTranscriptWords: [EditedTranscriptWord] {
        guard editSession.timeline != nil else { return [] }
        let visibleWords = visibleTranscriptPhrases.flatMap { phrase in
            expandedPhraseIDs.contains(phrase.id) ? phrase.words : []
        }
        let orderedIDs = transcriptWordSelection.orderedIDs(in: visibleWords.map(\.id))
        let wordsByID = Dictionary(uniqueKeysWithValues: visibleWords.map { ($0.id, $0) })
        return orderedIDs.compactMap { wordsByID[$0] }
    }

    private var selectedTranscriptPhrase: EditedTranscriptPhrase? {
        guard let transcript, let timeline = editSession.timeline else { return nil }
        return transcript.phrases(in: timeline).first { $0.id == selectedPhraseID }
    }

    private func transcriptTime(_ seconds: TimeInterval) -> String {
        String(format: "%02d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }

    private func focusTranscriptRange(_ range: Range<TimeInterval>) {
        selectedRange = range
        timelineFocusRequest = ProjectTimelineFocusRequest(range: range)
        Task { await editSession.player.seek(to: CMTime(seconds: range.lowerBound, preferredTimescale: 600)) }
    }

    private func deleteSelectedTranscriptWords() {
        guard focusedTranscriptWordID != nil, !selectedTranscriptWords.isEmpty else { return }
        if selectedTranscriptWords.contains(where: { $0.timingStatus == .uncertain }) {
            isConfirmingTranscriptWordDelete = true
        } else {
            Task { await applyTranscriptWordDeletion() }
        }
    }

    private func applyTranscriptWordDeletion() async {
        let selectedWords = selectedTranscriptWords
        guard !selectedWords.isEmpty else { return }
        let sortedRanges = selectedWords.map { $0.outputStart..<$0.outputEnd }
            .sorted { $0.lowerBound < $1.lowerBound }
        var ranges: [Range<TimeInterval>] = []
        for range in sortedRanges {
            if let last = ranges.last, range.lowerBound < last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                ranges.append(range)
            }
        }
        await editSession.deleteOutputRanges(ranges)
        if let error = editSession.errorMessage {
            transcriptError = error
        } else {
            transcriptWordSelection.clear()
            focusedTranscriptWordID = nil
            selectedPhraseID = nil
            selectedRange = nil
            transcriptError = nil
        }
    }

    private func transcriptWordButton(_ word: EditedTranscriptWord) -> some View {
        let visibleWords = visibleTranscriptPhrases.flatMap { phrase in
            expandedPhraseIDs.contains(phrase.id) ? phrase.words : []
        }
        let isSelected = transcriptWordSelection.selectedIDs.contains(word.id)
        return Button {
            transcriptWordSelection.select(
                word.id,
                extendingWithShift: NSEvent.modifierFlags.contains(.shift),
                orderedIDs: visibleWords.map(\.id)
            )
            selectedPhraseID = nil
            let selected = transcriptWordSelection.orderedIDs(in: visibleWords.map(\.id))
                .compactMap { id in visibleWords.first(where: { $0.id == id }) }
            if let first = selected.first, let last = selected.last {
                focusTranscriptRange(first.outputStart..<last.outputEnd)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(transcriptTime(word.outputStart))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)
                Text(word.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if word.timingStatus == .uncertain {
                    Image(systemName: "waveform.badge.exclamationmark")
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Color.accentColor.opacity(0.18) : .clear)
            .background(pendingAssistantCuts?.ranges.contains(where: {
                $0.lowerBound < word.outputEnd && $0.upperBound > word.outputStart
            }) == true ? Color.red.opacity(0.15) : .clear)
            .background(pendingAssistantMove.map {
                $0.range.lowerBound < word.outputEnd && $0.range.upperBound > word.outputStart
            } == true ? Color.blue.opacity(0.18) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedTranscriptWordID, equals: word.id)
        .accessibilityLabel("\(word.text), \(word.outputStart.formatted()) seconds, \(word.timingStatus.rawValue) timing")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func loadTranscript() {
        guard let projectID = project.identity.manifestID else { return }
        do {
            transcript = try TimedTranscriptStore().load(in: project.rootURL, expectedProjectID: projectID)
            transcriptError = nil
            transcriptFileUnreadable = false
        } catch {
            transcript = nil
            transcriptError = error.localizedDescription
            transcriptFileUnreadable = true
        }
    }

    private var transcriptionJob: RecordingJob? {
        guard let projectID = project.identity.manifestID else { return nil }
        return jobs.filter { $0.projectID == projectID && $0.kind == .transcription }
            .max { $0.updatedAt < $1.updatedAt }
    }

    private var transcriptionStatusText: String {
        if let transcriptionJob {
            switch transcriptionJob.state {
            case .queued, .running: return transcriptionJob.stage
            case .failed: return "\(transcriptionJob.failure ?? "Transcription failed.") Retry from Jobs."
            case .completed: return "The saved transcript is missing or belongs to another track."
            }
        }
        return "Ukrainian words are recognized locally. Experimental word boundaries need waveform review before cutting."
    }

    private func queueMissingTranscript() async {
        guard !isQueuingTranscription, transcriptError == nil,
              let projectID = project.identity.manifestID,
              let timeline = editSession.timeline,
              transcript?.isCompatible(with: timeline) != true,
              transcriptionJob?.state != .queued,
              transcriptionJob?.state != .running,
              transcriptionJob?.state != .failed,
              let audioURL = programSources?.audioURL ?? programScreenTrackURL else { return }
        isQueuingTranscription = true
        defer { isQueuingTranscription = false }
        do {
            try await queueTranscription(ProjectTranscriptionRecipe(
                projectID: projectID, sourceTrackID: timeline.trackID,
                sourceDuration: timeline.sourceDuration, audioURL: audioURL
            ))
        } catch {
            transcriptError = error.localizedDescription
        }
    }

    private func saveTranscriptText() {
        guard let transcript, let timeline = editSession.timeline, !transcript.words.isEmpty,
              let destination = saveURL(type: .plainText, suggestedName: "Recording transcript.txt") else { return }
        do {
            try transcript.words(in: timeline).map(\.text).joined(separator: " ")
                .write(to: destination, atomically: true, encoding: .utf8)
        } catch {
            transcriptError = error.localizedDescription
        }
    }

    private var editorCenter: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("All Projects", systemImage: "chevron.left", action: onClose)
                    .labelStyle(.iconOnly)
                if !isAssistantVisible {
                    Button("Show Assistant", systemImage: "sidebar.left") { isAssistantVisible = true }
                        .labelStyle(.iconOnly)
                }
                Text("Editor").font(.subheadline.weight(.semibold))
                TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                    HStack(spacing: 6) {
                        Button(
                            editSession.player.rate > 0 ? "Pause" : "Play",
                            systemImage: editSession.player.rate > 0 ? "pause.fill" : "play.fill"
                        ) {
                            if editSession.player.rate > 0 { editSession.player.pause() }
                            else { editSession.player.play() }
                        }
                        .labelStyle(.iconOnly)
                        .disabled(editSession.timeline == nil)
                        Text(String(format: "%d:%02d", Int(editSession.playhead) / 60, Int(editSession.playhead) % 60))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Label(lifecycleLabel, systemImage: lifecycleIcon)
                    .font(.caption)
                    .foregroundStyle(lifecycleColor)
                Button("Details", systemImage: "slider.horizontal.3") { isShowingDetails = true }
                    .labelStyle(.iconOnly)
                    .help("Scene, media and sharing details")
                    .popover(isPresented: $isShowingDetails) {
                        inspector.frame(width: 320, height: 560)
                    }
                if !isTranscriptVisible {
                    Button("Show Transcript", systemImage: "sidebar.right") { isTranscriptVisible = true }
                        .labelStyle(.iconOnly)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(detailPanel)
            Divider()
            if editSession.proposalPlayer != nil {
                HStack {
                    Label("Proposed output preview", systemImage: "play.rectangle")
                        .font(.caption)
                    Text("Timeline marks show the current edit until Apply.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Close Preview") { editSession.dismissProposalPreview() }
                        .font(.caption)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(detailPanel)
                Divider()
            }
            NativeVideoPlayer(player: editSession.proposalPlayer ?? editSession.player)
                .background(Color.black)
                .aspectRatio(editSession.presentation.canvas.aspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Composed program preview")
                .padding(12)
                .frame(minHeight: 220, maxHeight: .infinity)
                .background(detailContent)
            Divider()
            ScrollView {
                ProjectQuickEditorView(
                    session: editSession,
                    onExportMovie: exportEditedMovie,
                    selectedRange: $selectedRange,
                    proposedRanges: pendingAssistantCuts?.ranges ?? [],
                    proposedMove: pendingAssistantMove,
                    focusRequest: timelineFocusRequest,
                    requiresSelectionTimingReview:
                        selectedTranscriptWords.contains {
                            $0.requiresTimingReview(for: selectedRange)
                        }
                        || (pendingAssistantCuts?.requiresTimingReview == true
                            && pendingAssistantCuts?.ranges.contains(where: {
                                guard let selectedRange else { return false }
                                return selectedRange.lowerBound < $0.upperBound
                                    && selectedRange.upperBound > $0.lowerBound
                            }) == true)
                        || selectedTranscriptPhrase?.requiresTimingReview(for: selectedRange) == true
                )
                    .padding(12)
            }
            .frame(height: 290)
            .background(detailPanel)
            if let selectedTrackURL, FileManager.default.fileExists(atPath: selectedTrackURL.path) {
                Divider()
                HStack { shareActions(for: selectedTrackURL) }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(detailPanel)
            }
        }
    }

    private var detailContent: Color {
        colorScheme == .dark
            ? Color(red: 0.045, green: 0.048, blue: 0.052)
            : Color(red: 0.94, green: 0.935, blue: 0.925)
    }

    private var detailPanel: Color {
        colorScheme == .dark
            ? Color(red: 0.075, green: 0.078, blue: 0.084)
            : Color(red: 0.975, green: 0.97, blue: 0.96)
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
        let audioStemTrack = project.tracks.first { track in
            track.kind == .audio && isPlayable(track)
        }
        let legacyAudioTrack = project.primaryAudioDisplayID.flatMap { displayID in
            project.tracks.first { track in
                track.kind == .screen && track.displayID == displayID && isPlayable(track)
            }
        } ?? screen
        let audioTrack = audioStemTrack ?? legacyAudioTrack
        let indexedTracks = audioStemTrack == nil ? [] : (audioStemIndex?.tracks ?? [])
        let audioSourceTrackIDs = Dictionary(uniqueKeysWithValues: indexedTracks.map {
            ($0.persistentTrackID, $0.source)
        })
        let stemState = audioStemTrack.flatMap { stem in
            project.recoveryReport.tracks.first(where: { $0.id == stem.id })?.state
        }
        let legacyFinalizedOrder: [ProjectAudioSource] = indexedTracks.isEmpty
            && !audioStemIndexFileExists
            && stemState == .finalized
            ? ProjectAudioSource.allCases.filter {
                switch $0 {
                case .systemAudio: project.capturesSystemAudio
                case .microphone: project.capturesMicrophone
                }
            }
            : []
        let audioSourceOrder = indexedTracks.isEmpty
            ? legacyFinalizedOrder
            : ProjectAudioSource.allCases.filter { source in indexedTracks.contains { $0.source == source } }
        return ProjectProgramSources(
            screenURL: project.rootURL.appending(path: screen.relativePath),
            screenSources: project.tracks.filter { $0.kind == .screen }.map {
                ProjectScreenSource(
                    url: project.rootURL.appending(path: $0.relativePath),
                    displayID: $0.displayID
                )
            },
            cameraURL: camera.map { project.rootURL.appending(path: $0.relativePath) },
            audioURL: project.rootURL.appending(path: audioTrack.relativePath),
            audioSourceOrder: audioSourceOrder,
            audioSourceTrackIDs: audioSourceTrackIDs,
            screenDisplayID: project.programDisplayID ?? screen.displayID,
            cursorTimeline: cursorTimeline,
            shortcutTimeline: shortcutTimeline,
            sceneTimeline: studioSceneTimeline?.hasSceneSwitches == true ? studioSceneTimeline : nil,
            screenWasCapturedAsFixedRegion: project.presentation?.framing.mode == .fixedRegion,
            cameraTimeOffset: camera.map {
                ProjectTrackTiming.offset(
                    from: screen.id,
                    to: $0.id,
                    in: projectJournalEvents
                ) + project.cameraSyncOffset
            } ?? 0,
            rendersCursor: project.includesCursor && project.usesCompositedCursor,
            frameRate: project.frameRate
        )
    }

    private var audioStemIndex: ProjectAudioStemIndex? {
        let url = project.rootURL.appending(path: ProjectAudioStemIndex.filename)
        guard let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(ProjectAudioStemIndex.self, from: data),
              index.isValid else { return nil }
        return index
    }

    private var audioStemIndexFileExists: Bool {
        FileManager.default.fileExists(
            atPath: project.rootURL.appending(path: ProjectAudioStemIndex.filename).path
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

    private var shortcutTimeline: SafeShortcutTimeline? {
        let url = project.rootURL.appending(path: "scene/shortcuts.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SafeShortcutTimeline.self, from: data)
    }

    private var studioSceneTimeline: StudioSceneTimeline? {
        let url = project.rootURL.appending(path: "scene/layout.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StudioSceneTimeline.self, from: data)
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
        performExport(success: "Export queued in Jobs") {
            let recipe = try editSession.makeExportRecipe(to: destinationURL)
            try await queueExport(recipe)
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
        case .audio:
            return "System & microphone stems"
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
