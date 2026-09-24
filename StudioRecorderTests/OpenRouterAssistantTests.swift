import XCTest
@testable import StudioRecorder

final class OpenRouterAssistantTests: XCTestCase {
    func testCatalogOffersOnlyTextModelsWithStructuredOutputSupport() throws {
        let payload = Data("""
        {"data":[
          {"id":"openai/gpt-4.1-mini","name":"GPT-4.1 Mini","supported_parameters":["response_format","structured_outputs"],"architecture":{"output_modalities":["text"]}},
          {"id":"example/plain","name":"Plain","supported_parameters":["temperature"],"architecture":{"output_modalities":["text"]}},
          {"id":"example/json-only","name":"JSON only","supported_parameters":["response_format"],"architecture":{"output_modalities":["text"]}},
          {"id":"example/image","name":"Image","supported_parameters":["response_format"],"architecture":{"output_modalities":["image"]}}
        ]}
        """.utf8)

        XCTAssertEqual(try OpenRouterAssistantClient.compatibleModels(from: payload).map(\.id),
                       ["openai/gpt-4.1-mini"])
    }

    func testDraftRequestIncludesOnlyExplicitTextContextAndRequiresStructuredOutput() throws {
        let context = OpenRouterAssistantContext(
            projectID: UUID(), scope: .selection, words: [
                OpenRouterAssistantWord(id: UUID(), text: "Hello", start: 1.2, end: 1.5)
            ]
        )
        let request = try OpenRouterAssistantClient().draftRequest(
            apiKey: "private-key", model: "openai/gpt-4.1-mini",
            prompt: "Suggest titles", context: context
        )
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let provider = try XCTUnwrap(json["provider"] as? [String: Any])
        let format = try XCTUnwrap(json["response_format"] as? [String: Any])
        let schema = try XCTUnwrap(format["json_schema"] as? [String: Any])

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer private-key")
        XCTAssertEqual(provider["require_parameters"] as? Bool, true)
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(schema["strict"] as? Bool, true)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("private-key"))
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("file://"))
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("selection"))
    }

    func testDraftRequestCarriesPreviousConversationForRefinement() throws {
        let context = OpenRouterAssistantContext(projectID: UUID(), scope: .wholeProject, words: [])
        let history = [
            OpenRouterAssistantTurn(role: .user, content: "Suggest a concise title"),
            OpenRouterAssistantTurn(role: .assistant, content: "First title idea"),
        ]
        let request = try OpenRouterAssistantClient().draftRequest(
            apiKey: "private-key", model: "openai/gpt-4.1-mini",
            prompt: "Make it shorter", context: context, history: history
        )
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user", "assistant", "user"])
        XCTAssertEqual(messages[1]["content"], "Suggest a concise title")
        XCTAssertEqual(messages[2]["content"], "First title idea")
        XCTAssertTrue(messages[3]["content"]?.contains("Make it shorter") == true)
    }

    func testMalformedModelReplyCannotBecomeAVisibleDraft() throws {
        let valid = Data("""
        {"choices":[{"message":{"content":"{\\"reply\\":\\"Here are ideas\\",\\"titles\\":[\\"A title\\"],\\"descriptions\\":[],\\"new_take_wording\\":[]}"}}]}
        """.utf8)
        XCTAssertEqual(try OpenRouterAssistantClient.parseDraft(from: valid).titles, ["A title"])

        let invalid = Data("""
        {"choices":[{"message":{"content":"{\\"reply\\":\\" \",\\"titles\\":[],\\"descriptions\\":[],\\"new_take_wording\\":[]}"}}]}
        """.utf8)
        XCTAssertThrowsError(try OpenRouterAssistantClient.parseDraft(from: invalid))
    }
}
