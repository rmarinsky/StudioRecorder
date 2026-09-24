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

struct OpenRouterAssistantContext: Codable, Equatable, Sendable {
    let projectID: UUID
    let scope: OpenRouterAssistantScope
    let words: [OpenRouterAssistantWord]
    let silences: [OpenRouterAssistantSilence]

    init(
        projectID: UUID, scope: OpenRouterAssistantScope,
        words: [OpenRouterAssistantWord], silences: [OpenRouterAssistantSilence] = []
    ) {
        self.projectID = projectID
        self.scope = scope
        self.words = words
        self.silences = silences
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

    enum CodingKeys: String, CodingKey {
        case reply, titles, descriptions, cuts
        case newTakeWording = "new_take_wording"
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
                !$0.id.isEmpty && $0.reason.count <= 500
            }
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
}

struct OpenRouterAssistantCutTarget: Codable, Equatable, Sendable {
    let id: String
    let reason: String
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
        case .invalidProposal: "The proposed cuts do not match reviewed words or detected pauses in the current edit. No edits were applied."
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
              }) else { throw OpenRouterAssistantError.invalidContext }

        let contextJSON = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
        let string: [String: Any] = ["type": "string"]
        let strings: [String: Any] = ["type": "array", "items": string]
        let cut: [String: Any] = [
            "type": "object",
            "properties": ["id": string, "reason": string],
            "required": ["id", "reason"], "additionalProperties": false,
        ]
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "reply": string, "titles": strings, "descriptions": strings,
                "new_take_wording": strings,
                "cuts": ["type": "array", "items": cut],
            ],
            "required": ["reply", "titles", "descriptions", "new_take_wording", "cuts"],
            "additionalProperties": false,
        ]
        let messages = [["role": "system", "content": "You assist with a recorded video. Suggest cuts only by exact IDs of provided words with aligned or reviewed timing, or locally detected silences. Never invent IDs or time ranges. All cuts require human review and are not applied by this response. New wording is a script for another take, never recorded speech. Do not claim to have changed media."]]
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
