import Foundation

enum OpenRouterAssistantScope: String, Codable, Sendable {
    case wholeProject = "whole_project"
    case selection
}

struct OpenRouterAssistantWord: Codable, Equatable, Sendable {
    let id: UUID
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

struct OpenRouterAssistantContext: Codable, Equatable, Sendable {
    let projectID: UUID
    let scope: OpenRouterAssistantScope
    let words: [OpenRouterAssistantWord]
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

    enum CodingKeys: String, CodingKey {
        case reply, titles, descriptions
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
    }
}

enum OpenRouterAssistantError: LocalizedError {
    case missingKey
    case unsupportedModel
    case invalidContext
    case invalidReply
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .missingKey: "Add an OpenRouter key in Settings before using Assistant."
        case .unsupportedModel: "The selected model no longer supports structured replies. Choose another model."
        case .invalidContext: "The selected transcript contains invalid timing data."
        case .invalidReply: "The model returned an invalid reply. No edits were applied."
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
            .filter { $0.supportedParameters.contains("response_format")
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
        context: OpenRouterAssistantContext
    ) async throws -> OpenRouterAssistantDraft {
        let models = try await availableModels(apiKey: apiKey)
        guard models.contains(where: { $0.id == model }) else {
            throw OpenRouterAssistantError.unsupportedModel
        }
        let request = try draftRequest(apiKey: apiKey, model: model, prompt: prompt, context: context)
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        return try Self.parseDraft(from: data)
    }

    func draftRequest(
        apiKey: String, model: String, prompt: String,
        context: OpenRouterAssistantContext
    ) throws -> URLRequest {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenRouterAssistantError.missingKey
        }
        guard !model.isEmpty, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              context.words.allSatisfy({
                  $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.start < $0.end
              }) else { throw OpenRouterAssistantError.invalidContext }

        let contextJSON = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
        let string: [String: Any] = ["type": "string"]
        let strings: [String: Any] = ["type": "array", "items": string]
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "reply": string, "titles": strings, "descriptions": strings,
                "new_take_wording": strings,
            ],
            "required": ["reply", "titles", "descriptions", "new_take_wording"],
            "additionalProperties": false,
        ]
        let body: [String: Any] = [
            "model": model,
            "provider": ["require_parameters": true],
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "studio_recorder_draft", "strict": true, "schema": schema],
            ],
            "messages": [
                ["role": "system", "content": "You assist with a recorded video. Return only reviewed text suggestions. New wording is a script for another take, never recorded speech. Do not invent word timings or claim to have changed media."],
                ["role": "user", "content": "Context: \(contextJSON)\nRequest: \(prompt)"],
            ],
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
