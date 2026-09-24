import Foundation

enum OpenRouterAssistantScope: String, Codable, Sendable {
    case wholeProject = "whole_project"
    case selection
}

struct OpenRouterAssistantWord: Codable, Equatable, Sendable {
    let id: String
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let timingStatus: TranscriptTimingStatus
}

struct OpenRouterAssistantSilence: Codable, Equatable, Sendable {
    let id: String
    let start: TimeInterval
    let end: TimeInterval
}

struct OpenRouterAssistantSceneSelection: Codable, Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let capturedDisplayIDs: [UInt32]
    let hasCapturedCamera: Bool
    let overlays: [OpenRouterAssistantSceneOverlay]
    let currentState: OpenRouterAssistantSceneState?

    init(
        start: TimeInterval, end: TimeInterval,
        capturedDisplayIDs: [UInt32], hasCapturedCamera: Bool,
        overlays: [OpenRouterAssistantSceneOverlay] = [],
        currentState: OpenRouterAssistantSceneState? = nil
    ) {
        self.start = start
        self.end = end
        self.capturedDisplayIDs = capturedDisplayIDs
        self.hasCapturedCamera = hasCapturedCamera
        self.overlays = overlays
        self.currentState = currentState
    }
}

struct OpenRouterAssistantSceneOverlay: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
}

struct OpenRouterAssistantSceneState: Codable, Equatable, Sendable {
    let screenVisible: Bool
    let cameraVisible: Bool
    let displayID: UInt32?
    let cameraX: Double
    let cameraY: Double
    let cameraWidth: Double
    let cameraShape: SourceShape
    let cameraBackground: CameraBackgroundMode

    var isValid: Bool {
        cameraX.isFinite && (0...1).contains(cameraX)
            && cameraY.isFinite && (0...1).contains(cameraY)
            && cameraWidth.isFinite && (0.08...1).contains(cameraWidth)
    }
}

struct OpenRouterAssistantContext: Codable, Equatable, Sendable {
    let projectID: UUID
    let scope: OpenRouterAssistantScope
    let words: [OpenRouterAssistantWord]
    let silences: [OpenRouterAssistantSilence]
    let sceneSelection: OpenRouterAssistantSceneSelection?

    init(
        projectID: UUID, scope: OpenRouterAssistantScope,
        words: [OpenRouterAssistantWord], silences: [OpenRouterAssistantSilence] = [],
        sceneSelection: OpenRouterAssistantSceneSelection? = nil
    ) {
        self.projectID = projectID
        self.scope = scope
        self.words = words
        self.silences = silences
        self.sceneSelection = sceneSelection
    }
}

struct OpenRouterAssistantTurn: Equatable, Sendable {
    enum Role: String, Sendable { case user, assistant }
    let role: Role
    let content: String
}

struct OpenRouterAssistantModel: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
}

struct OpenRouterAssistantDraft: Codable, Equatable, Sendable {
    let reply: String
    let titles: [String]
    let descriptions: [String]
    let newTakeWording: [String]
    let cuts: [OpenRouterAssistantCutTarget]
    let sceneChanges: [OpenRouterAssistantSceneChange]
    let phraseMoves: [OpenRouterAssistantPhraseMove]

    enum CodingKeys: String, CodingKey {
        case reply, titles, descriptions, cuts
        case newTakeWording = "new_take_wording"
        case sceneChanges = "scene_changes"
        case phraseMoves = "phrase_moves"
    }

    init(
        reply: String, titles: [String], descriptions: [String],
        newTakeWording: [String], cuts: [OpenRouterAssistantCutTarget],
        sceneChanges: [OpenRouterAssistantSceneChange] = [],
        phraseMoves: [OpenRouterAssistantPhraseMove] = []
    ) {
        self.reply = reply
        self.titles = titles
        self.descriptions = descriptions
        self.newTakeWording = newTakeWording
        self.cuts = cuts
        self.sceneChanges = sceneChanges
        self.phraseMoves = phraseMoves
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reply = try container.decode(String.self, forKey: .reply)
        titles = try container.decode([String].self, forKey: .titles)
        descriptions = try container.decode([String].self, forKey: .descriptions)
        newTakeWording = try container.decode([String].self, forKey: .newTakeWording)
        cuts = try container.decode([OpenRouterAssistantCutTarget].self, forKey: .cuts)
        sceneChanges = try container.decodeIfPresent(
            [OpenRouterAssistantSceneChange].self, forKey: .sceneChanges
        ) ?? []
        phraseMoves = try container.decodeIfPresent(
            [OpenRouterAssistantPhraseMove].self, forKey: .phraseMoves
        ) ?? []
    }

    var isValid: Bool {
        !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && reply.count <= 12_000
            && [titles, descriptions, newTakeWording].allSatisfy { values in
                values.count <= 8 && values.allSatisfy {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 5_000
                }
            }
            && cuts.count <= 30
            && cuts.allSatisfy {
                !$0.id.isEmpty && !$0.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.reason.count <= 500
            }
            && sceneChanges.count <= 1
            && phraseMoves.count <= 1
            && [!cuts.isEmpty, !sceneChanges.isEmpty, !phraseMoves.isEmpty]
                .count(where: { $0 }) <= 1
            && sceneChanges.allSatisfy { $0.isValid }
            && phraseMoves.allSatisfy { $0.isValid }
    }

    func reviewedCuts(
        context: OpenRouterAssistantContext,
        timeline: ProjectEditTimeline,
        revision: Int
    ) throws -> OpenRouterReviewedCuts {
        let allIDs = context.words.map(\.id) + context.silences.map(\.id)
        guard Set(allIDs).count == allIDs.count,
              Set(cuts.map(\.id)).count == cuts.count else {
            throw OpenRouterAssistantError.invalidProposal
        }
        let words = Dictionary(uniqueKeysWithValues: context.words.map { ($0.id, $0) })
        let silences = Dictionary(uniqueKeysWithValues: context.silences.map { ($0.id, $0) })
        let ranges = try cuts.map { cut -> Range<TimeInterval> in
            let start: TimeInterval
            let end: TimeInterval
            if let word = words[cut.id], word.timingStatus != .uncertain {
                start = word.start
                end = word.end
            } else if let silence = silences[cut.id] {
                start = silence.start
                end = silence.end
            } else {
                throw OpenRouterAssistantError.invalidProposal
            }
            guard start.isFinite, end.isFinite, start >= 0,
                  start < end, end <= timeline.duration else {
                throw OpenRouterAssistantError.invalidProposal
            }
            return start..<end
        }.sorted { $0.lowerBound < $1.lowerBound }
        guard zip(ranges, ranges.dropFirst()).allSatisfy({ $0.0.upperBound <= $0.1.lowerBound }) else {
            throw OpenRouterAssistantError.invalidProposal
        }
        return OpenRouterReviewedCuts(
            projectID: context.projectID, timeline: timeline, revision: revision, ranges: ranges
        )
    }

    func reviewedScene(
        context: OpenRouterAssistantContext,
        timeline: ProjectEditTimeline,
        revision: Int
    ) throws -> OpenRouterReviewedScene? {
        guard let change = sceneChanges.first else { return nil }
        guard sceneChanges.count == 1, change.isValid,
              context.scope == .selection,
              let selection = context.sceneSelection,
              selection.start.isFinite, selection.end.isFinite,
              selection.start >= 0, selection.start < selection.end,
              selection.end <= timeline.duration,
              (try? timeline.sourceRange(for: selection.start..<selection.end)) != nil,
              (!change.layout.usesCamera || selection.hasCapturedCamera),
              (!change.layout.usesScreen || !selection.capturedDisplayIDs.isEmpty),
              (!change.hasCameraCustomization || change.layout.usesCamera && selection.hasCapturedCamera),
              (change.displayID == nil || change.layout.usesScreen),
              (change.displayID.map { selection.capturedDisplayIDs.contains($0) } ?? true),
              (change.overlayID.map { overlayID in
                  selection.overlays.contains { $0.id == overlayID }
              } ?? true) else {
            throw OpenRouterAssistantError.invalidProposal
        }
        return OpenRouterReviewedScene(
            projectID: context.projectID, timeline: timeline, revision: revision,
            range: selection.start..<selection.end, change: change
        )
    }

    func reviewedMove(
        context: OpenRouterAssistantContext,
        timeline: ProjectEditTimeline,
        revision: Int
    ) throws -> OpenRouterReviewedMove? {
        guard let move = phraseMoves.first else { return nil }
        guard phraseMoves.count == 1, move.isValid,
              context.scope == .wholeProject,
              Set(context.words.map(\.id)).count == context.words.count,
              let firstIndex = context.words.firstIndex(where: { $0.id == move.firstWordID }),
              let lastIndex = context.words.firstIndex(where: { $0.id == move.lastWordID }),
              firstIndex <= lastIndex else { throw OpenRouterAssistantError.invalidProposal }
        let first = context.words[firstIndex]
        let last = context.words[lastIndex]
        guard first.timingStatus != .uncertain, last.timingStatus != .uncertain,
              first.start.isFinite, last.end.isFinite,
              first.start >= 0, first.start < last.end,
              last.end <= timeline.duration else { throw OpenRouterAssistantError.invalidProposal }
        let destination: TimeInterval
        if move.beforeWordID.isEmpty {
            destination = timeline.duration
        } else {
            guard let target = context.words.first(where: { $0.id == move.beforeWordID }),
                  target.timingStatus != .uncertain else {
                throw OpenRouterAssistantError.invalidProposal
            }
            destination = target.start
        }
        let range = first.start..<last.end
        guard destination != range.lowerBound, destination != range.upperBound else {
            throw OpenRouterAssistantError.invalidProposal
        }
        var validated = timeline
        do { try validated.move(range: range, before: destination) }
        catch { throw OpenRouterAssistantError.invalidProposal }
        return OpenRouterReviewedMove(
            projectID: context.projectID, timeline: timeline, revision: revision,
            range: range, destination: destination, reason: move.reason
        )
    }
}

struct OpenRouterAssistantCutTarget: Codable, Equatable, Sendable {
    let id: String
    let reason: String
}

struct OpenRouterAssistantPhraseMove: Codable, Equatable, Sendable {
    let firstWordID: String
    let lastWordID: String
    let beforeWordID: String
    let reason: String

    enum CodingKeys: String, CodingKey {
        case firstWordID = "first_word_id"
        case lastWordID = "last_word_id"
        case beforeWordID = "before_word_id"
        case reason
    }

    var isValid: Bool {
        !firstWordID.isEmpty && !lastWordID.isEmpty
            && !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && reason.count <= 500
    }
}

struct OpenRouterReviewedMove: Equatable, Sendable {
    let projectID: UUID
    let timeline: ProjectEditTimeline
    let revision: Int
    let range: Range<TimeInterval>
    let destination: TimeInterval
    let reason: String

    func isCurrent(projectID: UUID, timeline: ProjectEditTimeline, revision: Int) -> Bool {
        self.projectID == projectID && self.timeline == timeline && self.revision == revision
    }
}

enum OpenRouterAssistantSceneLayout: String, Codable, Sendable {
    case screenOnly = "screen_only"
    case cameraOnly = "camera_only"
    case screenAndCamera = "screen_and_camera"

    var usesScreen: Bool { self != .cameraOnly }
    var usesCamera: Bool { self != .screenOnly }
    var label: String {
        switch self {
        case .screenOnly: "Screen"
        case .cameraOnly: "Camera"
        case .screenAndCamera: "Screen and Camera"
        }
    }
}

struct OpenRouterAssistantSceneChange: Codable, Equatable, Sendable {
    let layout: OpenRouterAssistantSceneLayout
    let transition: StudioSceneTransitionEffect
    let duration: TimeInterval
    let reason: String
    let displayID: UInt32?
    let cameraX: Double?
    let cameraY: Double?
    let cameraWidth: Double?
    let cameraShape: SourceShape?
    let cameraBackground: CameraBackgroundMode?
    let overlayID: UUID?
    let overlayVisible: Bool?

    enum CodingKeys: String, CodingKey {
        case layout, transition, duration, reason
        case displayID = "display_id"
        case cameraX = "camera_x"
        case cameraY = "camera_y"
        case cameraWidth = "camera_width"
        case cameraShape = "camera_shape"
        case cameraBackground = "camera_background"
        case overlayID = "overlay_id"
        case overlayVisible = "overlay_visible"
    }

    init(
        layout: OpenRouterAssistantSceneLayout,
        transition: StudioSceneTransitionEffect,
        duration: TimeInterval,
        reason: String,
        displayID: UInt32? = nil,
        cameraX: Double? = nil,
        cameraY: Double? = nil,
        cameraWidth: Double? = nil,
        cameraShape: SourceShape? = nil,
        cameraBackground: CameraBackgroundMode? = nil,
        overlayID: UUID? = nil,
        overlayVisible: Bool? = nil
    ) {
        self.layout = layout
        self.transition = transition
        self.duration = duration
        self.reason = reason
        self.displayID = displayID
        self.cameraX = cameraX
        self.cameraY = cameraY
        self.cameraWidth = cameraWidth
        self.cameraShape = cameraShape
        self.cameraBackground = cameraBackground
        self.overlayID = overlayID
        self.overlayVisible = overlayVisible
    }

    var hasCameraCustomization: Bool {
        cameraX != nil || cameraY != nil || cameraWidth != nil
            || cameraShape != nil || cameraBackground != nil
    }

    var isValid: Bool {
        duration.isFinite && (0.15...1).contains(duration)
            && !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && reason.count <= 500
            && [cameraX, cameraY].allSatisfy { $0.map { $0.isFinite && (0...1).contains($0) } ?? true }
            && (cameraWidth.map { $0.isFinite && (0.08...1).contains($0) } ?? true)
            && ((overlayID == nil) == (overlayVisible == nil))
    }

    func presentation(from current: CapturePresentationSnapshot) -> CapturePresentationSnapshot {
        var next = current
        next.screen.isVisible = layout.usesScreen
        next.camera.isVisible = layout.usesCamera
        if layout == .cameraOnly {
            next.camera.centerX = 0.5
            next.camera.centerY = 0.5
            next.camera.width = 1
            next.camera.height = 1
            next.camera.shape = .rectangle
        } else if layout == .screenAndCamera && next.camera.width >= 0.8 {
            next.camera = CapturePresentationSnapshot.default.camera
        }
        if let cameraX { next.camera.centerX = cameraX }
        if let cameraY { next.camera.centerY = cameraY }
        if let cameraWidth { next.camera.width = cameraWidth }
        if let cameraShape { next.camera.shape = cameraShape }
        if let cameraBackground { next.cameraBackground = CameraBackgroundSnapshot(mode: cameraBackground) }
        if let overlayID, let overlayVisible {
            next.imageOverlays = current.resolvedImageOverlays.map { overlay in
                var overlay = overlay
                if overlay.id == overlayID { overlay.placement.isVisible = overlayVisible }
                return overlay
            }
        }
        return next.validated()
    }
}

struct OpenRouterReviewedScene: Equatable, Sendable {
    let projectID: UUID
    let timeline: ProjectEditTimeline
    let revision: Int
    let range: Range<TimeInterval>
    let change: OpenRouterAssistantSceneChange

    func isCurrent(projectID: UUID, timeline: ProjectEditTimeline, revision: Int) -> Bool {
        self.projectID == projectID && self.timeline == timeline && self.revision == revision
    }
}

struct OpenRouterReviewedCuts: Equatable, Sendable {
    let projectID: UUID
    let timeline: ProjectEditTimeline
    let revision: Int
    let ranges: [Range<TimeInterval>]

    func isCurrent(projectID: UUID, timeline: ProjectEditTimeline, revision: Int) -> Bool {
        self.projectID == projectID && self.timeline == timeline && self.revision == revision
    }
}

enum OpenRouterAssistantError: LocalizedError {
    case missingKey
    case unsupportedModel
    case invalidContext
    case invalidReply
    case invalidProposal
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .missingKey: "Add an OpenRouter key in Settings before using Assistant."
        case .unsupportedModel: "The selected model no longer supports structured replies. Choose another model."
        case .invalidContext: "The selected transcript contains invalid timing data."
        case .invalidReply: "The model returned an invalid reply. No edits were applied."
        case .invalidProposal: "The proposed edit does not match the current selection, captured sources, or reviewed word times. No edits were applied."
        case .requestFailed(let status): "OpenRouter request failed (HTTP \(status)). No edits were applied."
        }
    }
}

struct OpenRouterAssistantKeyStore {
    private let keychain = KeychainStreamCredentialStore(
        service: "ua.com.rmarinsky.studiorecorder.openrouter",
        account: "openrouter-api-key"
    )

    func load() throws -> String? { try keychain.loadStreamKey() }
    func save(_ key: String) throws { try keychain.saveStreamKey(key) }
    func delete() throws { try keychain.deleteStreamKey() }
}

struct OpenRouterAssistantClient {
    static let defaultModel = "openai/gpt-4.1-mini"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func compatibleModels(from data: Data) throws -> [OpenRouterAssistantModel] {
        struct Catalog: Decodable {
            struct Model: Decodable {
                struct Architecture: Decodable {
                    let outputModalities: [String]
                    enum CodingKeys: String, CodingKey { case outputModalities = "output_modalities" }
                }
                let id: String
                let name: String
                let supportedParameters: [String]
                let architecture: Architecture
                enum CodingKeys: String, CodingKey {
                    case id, name, architecture
                    case supportedParameters = "supported_parameters"
                }
            }
            let data: [Model]
        }
        return try JSONDecoder().decode(Catalog.self, from: data).data
            .filter { $0.supportedParameters.contains("structured_outputs")
                && $0.architecture.outputModalities.contains("text") }
            .map { OpenRouterAssistantModel(id: $0.id, name: $0.name) }
            .sorted { $0.id == defaultModel ? true : $1.id == defaultModel ? false : $0.name < $1.name }
    }

    func availableModels(apiKey: String) async throws -> [OpenRouterAssistantModel] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenRouterAssistantError.missingKey
        }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        return try Self.compatibleModels(from: data)
    }

    func draft(
        apiKey: String, model: String, prompt: String,
        context: OpenRouterAssistantContext,
        history: [OpenRouterAssistantTurn] = []
    ) async throws -> OpenRouterAssistantDraft {
        let models = try await availableModels(apiKey: apiKey)
        guard models.contains(where: { $0.id == model }) else {
            throw OpenRouterAssistantError.unsupportedModel
        }
        let request = try draftRequest(
            apiKey: apiKey, model: model, prompt: prompt, context: context, history: history
        )
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        return try Self.parseDraft(from: data)
    }

    func draftRequest(
        apiKey: String, model: String, prompt: String,
        context: OpenRouterAssistantContext,
        history: [OpenRouterAssistantTurn] = []
    ) throws -> URLRequest {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenRouterAssistantError.missingKey
        }
        guard !model.isEmpty, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              history.count <= 12,
              history.allSatisfy({
                  !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && $0.content.count <= 12_000
              }),
              context.words.allSatisfy({
                  $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.start < $0.end
              }),
              context.silences.allSatisfy({
                  $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.start < $0.end
              }),
              context.sceneSelection.map({
                  $0.start.isFinite && $0.end.isFinite
                      && $0.start >= 0 && $0.start < $0.end
                      && Set($0.capturedDisplayIDs).count == $0.capturedDisplayIDs.count
                      && Set($0.overlays.map(\.id)).count == $0.overlays.count
                      && $0.overlays.allSatisfy {
                          !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              && $0.name.count <= 80
                      }
                      && ($0.currentState?.isValid ?? true)
              }) ?? true else { throw OpenRouterAssistantError.invalidContext }

        let contextJSON = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
        let string: [String: Any] = ["type": "string"]
        let strings: [String: Any] = ["type": "array", "items": string]
        let optionalNumber: [String: Any] = ["type": ["number", "null"]]
        let optionalInteger: [String: Any] = ["type": ["integer", "null"]]
        let optionalString: [String: Any] = ["type": ["string", "null"]]
        let optionalBoolean: [String: Any] = ["type": ["boolean", "null"]]
        let cut: [String: Any] = [
            "type": "object",
            "properties": ["id": string, "reason": string],
            "required": ["id", "reason"], "additionalProperties": false,
        ]
        let sceneChange: [String: Any] = [
            "type": "object",
            "properties": [
                "layout": ["type": "string", "enum": ["screen_only", "camera_only", "screen_and_camera"]],
                "transition": ["type": "string", "enum": ["cut", "dissolve", "smoothMove"]],
                "duration": ["type": "number"],
                "reason": string,
                "display_id": optionalInteger,
                "camera_x": optionalNumber,
                "camera_y": optionalNumber,
                "camera_width": optionalNumber,
                "camera_shape": ["type": ["string", "null"],
                                 "enum": SourceShape.allCases.map { $0.rawValue as Any } + [NSNull()]],
                "camera_background": ["type": ["string", "null"],
                                      "enum": CameraBackgroundMode.allCases.map { $0.rawValue as Any } + [NSNull()]],
                "overlay_id": optionalString,
                "overlay_visible": optionalBoolean,
            ],
            "required": ["layout", "transition", "duration", "reason", "display_id",
                         "camera_x", "camera_y", "camera_width", "camera_shape",
                         "camera_background", "overlay_id", "overlay_visible"],
            "additionalProperties": false,
        ]
        let phraseMove: [String: Any] = [
            "type": "object",
            "properties": [
                "first_word_id": string, "last_word_id": string,
                "before_word_id": string, "reason": string,
            ],
            "required": ["first_word_id", "last_word_id", "before_word_id", "reason"],
            "additionalProperties": false,
        ]
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "reply": string, "titles": strings, "descriptions": strings,
                "new_take_wording": strings,
                "cuts": ["type": "array", "items": cut],
                "scene_changes": ["type": "array", "items": sceneChange],
                "phrase_moves": ["type": "array", "items": phraseMove],
            ],
            "required": ["reply", "titles", "descriptions", "new_take_wording", "cuts", "scene_changes", "phrase_moves"],
            "additionalProperties": false,
        ]
        let messages = [["role": "system", "content": "You assist with a recorded video. Suggest cuts only by exact IDs of provided words with aligned or reviewed timing, or locally detected silences. Scene changes apply only to the explicit selection and captured screen/camera sources in sceneSelection; use no more than one scene change. Scene display_id must be a captured display; overlay_id must be an existing imported PNG ID. Camera coordinates are normalized 0 to 1 and width 0.08 to 1. Use null for unchanged optional scene fields. To move a recorded phrase, use exact first and last word IDs in playback order and a before_word_id for its destination; use an empty before_word_id to append at the end. Phrase moves require whole-project scope and aligned or reviewed timing for the first, last, and destination words. Use no more than one media operation type per reply. For cuts use no invented IDs or times. For scene transitions use duration 0.15 to 1 seconds. All media edits require human review and are not applied by this response. New wording is a script for another take, never recorded speech. Do not claim to have changed media."]]
            + history.map { ["role": $0.role.rawValue, "content": $0.content] }
            + [["role": "user", "content": "Context: \(contextJSON)\nRequest: \(prompt)"]]
        let body: [String: Any] = [
            "model": model,
            "provider": ["require_parameters": true],
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "studio_recorder_draft", "strict": true, "schema": schema],
            ],
            "messages": messages,
        ]
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func parseDraft(from data: Data) throws -> OpenRouterAssistantDraft {
        struct Completion: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        guard let content = try? JSONDecoder().decode(Completion.self, from: data).choices.first?.message.content,
              let draft = try? JSONDecoder().decode(OpenRouterAssistantDraft.self, from: Data(content.utf8)),
              draft.isValid else { throw OpenRouterAssistantError.invalidReply }
        return draft
    }

    private static func check(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else {
            throw OpenRouterAssistantError.invalidReply
        }
        guard (200..<300).contains(response.statusCode) else {
            throw OpenRouterAssistantError.requestFailed(response.statusCode)
        }
    }
}
