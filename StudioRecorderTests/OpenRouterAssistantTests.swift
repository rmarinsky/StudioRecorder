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
                OpenRouterAssistantWord(id: "hello", text: "Hello", start: 1.2, end: 1.5,
                                        timingStatus: .aligned)
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
        let rootSchema = try XCTUnwrap(schema["schema"] as? [String: Any])
        let rootProperties = try XCTUnwrap(rootSchema["properties"] as? [String: Any])
        let sceneChanges = try XCTUnwrap(rootProperties["scene_changes"] as? [String: Any])
        let sceneItem = try XCTUnwrap(sceneChanges["items"] as? [String: Any])
        let sceneProperties = try XCTUnwrap(sceneItem["properties"] as? [String: Any])
        XCTAssertNotNil(sceneProperties["camera_x"])
        XCTAssertNotNil(sceneProperties["overlay_id"])
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

    func testSceneContextCarriesCurrentLayoutWithoutLocalImagePath() throws {
        let context = OpenRouterAssistantContext(
            projectID: UUID(), scope: .selection, words: [],
            sceneSelection: OpenRouterAssistantSceneSelection(
                start: 1, end: 2, capturedDisplayIDs: [42], hasCapturedCamera: true,
                overlays: [OpenRouterAssistantSceneOverlay(id: UUID(), name: "Logo")],
                currentState: OpenRouterAssistantSceneState(
                    screenVisible: true, cameraVisible: true, displayID: 42,
                    cameraX: 0.86, cameraY: 0.82, cameraWidth: 0.22,
                    cameraShape: .circle, cameraBackground: .off
                )
            )
        )
        let request = try OpenRouterAssistantClient().draftRequest(
            apiKey: "private-key", model: "openai/gpt-4.1-mini",
            prompt: "Move camera left", context: context
        )
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        let content = try XCTUnwrap(messages.last?["content"])

        XCTAssertTrue(content.contains("0.86"))
        XCTAssertTrue(content.contains("Logo"))
        XCTAssertFalse(content.contains("scene/images/"))
    }

    func testMalformedModelReplyCannotBecomeAVisibleDraft() throws {
        let valid = Data("""
        {"choices":[{"message":{"content":"{\\"reply\\":\\"Here are ideas\\",\\"titles\\":[\\"A title\\"],\\"descriptions\\":[],\\"new_take_wording\\":[],\\"cuts\\":[]}"}}]}
        """.utf8)
        XCTAssertEqual(try OpenRouterAssistantClient.parseDraft(from: valid).titles, ["A title"])

        let invalid = Data("""
        {"choices":[{"message":{"content":"{\\"reply\\":\\" \",\\"titles\\":[],\\"descriptions\\":[],\\"new_take_wording\\":[],\\"cuts\\":[]}"}}]}
        """.utf8)
        XCTAssertThrowsError(try OpenRouterAssistantClient.parseDraft(from: invalid))
    }

    func testCutProposalAcceptsOnlyKnownReviewedTargetsForCurrentRevision() throws {
        let projectID = UUID()
        let context = OpenRouterAssistantContext(
            projectID: projectID, scope: .wholeProject,
            words: [
                OpenRouterAssistantWord(id: "reviewed", text: "um", start: 1, end: 1.3,
                                        timingStatus: .reviewed),
                OpenRouterAssistantWord(id: "uncertain", text: "maybe", start: 2, end: 2.4,
                                        timingStatus: .uncertain),
            ]
        )
        let timeline = try ProjectEditTimeline(trackID: "screen", sourceDuration: 3)
        let valid = OpenRouterAssistantDraft(reply: "Remove a filler", titles: [], descriptions: [],
                                             newTakeWording: [], cuts: [
                                                OpenRouterAssistantCutTarget(id: "reviewed", reason: "Filler")
                                             ])
        let proposal = try valid.reviewedCuts(context: context, timeline: timeline, revision: 5)
        XCTAssertEqual(proposal.ranges, [1..<1.3])
        XCTAssertTrue(proposal.isCurrent(projectID: projectID, timeline: timeline, revision: 5))
        XCTAssertFalse(proposal.isCurrent(projectID: projectID, timeline: timeline, revision: 6))

        let uncertain = OpenRouterAssistantDraft(reply: "Remove", titles: [], descriptions: [],
                                                 newTakeWording: [], cuts: [
                                                    OpenRouterAssistantCutTarget(id: "uncertain", reason: "Filler")
                                                 ])
        XCTAssertThrowsError(try uncertain.reviewedCuts(context: context, timeline: timeline, revision: 5))
        let invented = OpenRouterAssistantDraft(reply: "Remove", titles: [], descriptions: [],
                                                newTakeWording: [], cuts: [
                                                    OpenRouterAssistantCutTarget(id: "invented", reason: "Filler")
                                                ])
        XCTAssertThrowsError(try invented.reviewedCuts(context: context, timeline: timeline, revision: 5))
    }

    func testCutProposalCanReferenceOnlyLocallyDetectedSilence() throws {
        let context = OpenRouterAssistantContext(
            projectID: UUID(), scope: .wholeProject, words: [],
            silences: [OpenRouterAssistantSilence(id: "silence-0", start: 1, end: 1.8)]
        )
        let timeline = try ProjectEditTimeline(trackID: "screen", sourceDuration: 3)
        let draft = OpenRouterAssistantDraft(
            reply: "Remove the long pause", titles: [], descriptions: [], newTakeWording: [],
            cuts: [OpenRouterAssistantCutTarget(id: "silence-0", reason: "Long pause")]
        )
        XCTAssertEqual(try draft.reviewedCuts(context: context, timeline: timeline, revision: 2).ranges,
                       [1..<1.8])
        let unknown = OpenRouterAssistantDraft(
            reply: "Remove", titles: [], descriptions: [], newTakeWording: [],
            cuts: [OpenRouterAssistantCutTarget(id: "silence-1", reason: "Invented pause")]
        )
        XCTAssertThrowsError(try unknown.reviewedCuts(context: context, timeline: timeline, revision: 2))
    }

    func testSceneProposalRequiresSelectedRangeAndCapturedSources() throws {
        let projectID = UUID()
        let timeline = try ProjectEditTimeline(trackID: "screen", sourceDuration: 10)
        let selected = 2.0..<4.0
        let scene = OpenRouterAssistantSceneChange(
            layout: .cameraOnly, transition: .dissolve, duration: 0.4,
            reason: "Focus on the speaker"
        )
        let draft = OpenRouterAssistantDraft(
            reply: "Use the camera here", titles: [], descriptions: [], newTakeWording: [],
            cuts: [], sceneChanges: [scene]
        )
        let context = OpenRouterAssistantContext(
            projectID: projectID, scope: .selection, words: [],
            sceneSelection: OpenRouterAssistantSceneSelection(
                start: 2, end: 4, capturedDisplayIDs: [42], hasCapturedCamera: true
            )
        )
        let reviewed = try draft.reviewedScene(context: context, timeline: timeline, revision: 3)
        XCTAssertEqual(reviewed?.range, selected)
        XCTAssertEqual(reviewed?.change.layout, .cameraOnly)
        XCTAssertTrue(reviewed?.isCurrent(projectID: projectID, timeline: timeline, revision: 3) == true)
        XCTAssertFalse(reviewed?.isCurrent(projectID: projectID, timeline: timeline, revision: 4) == true)

        var reordered = timeline
        try reordered.split(at: 5)
        try reordered.move(segmentID: reordered.segments[0].id, toIndex: 1)
        let acrossCut = OpenRouterAssistantContext(
            projectID: projectID, scope: .selection, words: [],
            sceneSelection: OpenRouterAssistantSceneSelection(
                start: 4.5, end: 5.5, capturedDisplayIDs: [42], hasCapturedCamera: true
            )
        )
        XCTAssertEqual(
            try draft.reviewedScene(context: acrossCut, timeline: reordered, revision: 3)?.range,
            4.5..<5.5
        )

        let noCamera = OpenRouterAssistantContext(
            projectID: projectID, scope: .selection, words: [],
            sceneSelection: OpenRouterAssistantSceneSelection(
                start: 2, end: 4, capturedDisplayIDs: [42], hasCapturedCamera: false
            )
        )
        XCTAssertThrowsError(try draft.reviewedScene(context: noCamera, timeline: timeline, revision: 3))
        XCTAssertThrowsError(try draft.reviewedScene(
            context: OpenRouterAssistantContext(projectID: projectID, scope: .wholeProject, words: []),
            timeline: timeline, revision: 3
        ))
    }

    func testPhraseMoveUsesOnlyReviewedWordBoundariesAndCurrentRevision() throws {
        let projectID = UUID()
        let timeline = try ProjectEditTimeline(trackID: "program", sourceDuration: 10)
        let words = [
            OpenRouterAssistantWord(id: "first", text: "Перша", start: 1, end: 1.3, timingStatus: .reviewed),
            OpenRouterAssistantWord(id: "last", text: "фраза", start: 1.4, end: 1.7, timingStatus: .reviewed),
            OpenRouterAssistantWord(id: "target", text: "Наступна", start: 7, end: 7.4, timingStatus: .reviewed),
        ]
        let context = OpenRouterAssistantContext(projectID: projectID, scope: .wholeProject, words: words)
        let move = OpenRouterAssistantPhraseMove(
            firstWordID: "first", lastWordID: "last", beforeWordID: "target",
            reason: "Put the introduction later"
        )
        let draft = OpenRouterAssistantDraft(
            reply: "Move the recorded phrase", titles: [], descriptions: [],
            newTakeWording: [], cuts: [], phraseMoves: [move]
        )

        let proposal = try XCTUnwrap(draft.reviewedMove(context: context, timeline: timeline, revision: 4))
        XCTAssertEqual(proposal.range, 1..<1.7)
        XCTAssertEqual(proposal.destination, 7)
        XCTAssertTrue(proposal.isCurrent(projectID: projectID, timeline: timeline, revision: 4))
        XCTAssertFalse(proposal.isCurrent(projectID: projectID, timeline: timeline, revision: 5))

        let uncertainContext = OpenRouterAssistantContext(
            projectID: projectID, scope: .wholeProject,
            words: [words[0], OpenRouterAssistantWord(
                id: "last", text: "фраза", start: 1.4, end: 1.7, timingStatus: .uncertain
            ), words[2]]
        )
        XCTAssertThrowsError(try draft.reviewedMove(
            context: uncertainContext, timeline: timeline, revision: 4
        ))
        let invented = OpenRouterAssistantDraft(
            reply: "Move", titles: [], descriptions: [], newTakeWording: [], cuts: [],
            phraseMoves: [OpenRouterAssistantPhraseMove(
                firstWordID: "invented", lastWordID: "last", beforeWordID: "target", reason: "Move"
            )]
        )
        XCTAssertThrowsError(try invented.reviewedMove(context: context, timeline: timeline, revision: 4))
    }

    func testSceneProposalRejectsInvalidTransitionAndMissingDisplay() throws {
        let timeline = try ProjectEditTimeline(trackID: "screen", sourceDuration: 10)
        let context = OpenRouterAssistantContext(
            projectID: UUID(), scope: .selection, words: [],
            sceneSelection: OpenRouterAssistantSceneSelection(
                start: 1, end: 3, capturedDisplayIDs: [], hasCapturedCamera: true
            )
        )
        let screenDraft = OpenRouterAssistantDraft(
            reply: "Show the screen", titles: [], descriptions: [], newTakeWording: [], cuts: [],
            sceneChanges: [OpenRouterAssistantSceneChange(
                layout: .screenOnly, transition: .cut, duration: 0.15, reason: "Show content"
            )]
        )
        XCTAssertThrowsError(try screenDraft.reviewedScene(context: context, timeline: timeline, revision: 1))
        let badDuration = OpenRouterAssistantDraft(
            reply: "Show the camera", titles: [], descriptions: [], newTakeWording: [], cuts: [],
            sceneChanges: [OpenRouterAssistantSceneChange(
                layout: .cameraOnly, transition: .dissolve, duration: 4, reason: "Focus"
            )]
        )
        XCTAssertThrowsError(try badDuration.reviewedScene(context: context, timeline: timeline, revision: 1))
    }

    func testSceneProposalChangesOnlyCapturedDisplayAndImportedCameraOverlaySettings() throws {
        let overlayID = UUID()
        var current = CapturePresentationSnapshot.default
        current.imageOverlays = [ImageOverlaySnapshot(
            id: overlayID, name: "Logo", filePath: "scene/images/logo.png",
            placement: SourcePlacementSnapshot(centerX: 0.5, centerY: 0.5, width: 0.3, shape: .rectangle)
        )]
        let timeline = try ProjectEditTimeline(trackID: "screen", sourceDuration: 10)
        let context = OpenRouterAssistantContext(
            projectID: UUID(), scope: .selection, words: [],
            sceneSelection: OpenRouterAssistantSceneSelection(
                start: 2, end: 4, capturedDisplayIDs: [42], hasCapturedCamera: true,
                overlays: [OpenRouterAssistantSceneOverlay(id: overlayID, name: "Logo")]
            )
        )
        let change = OpenRouterAssistantSceneChange(
            layout: .screenAndCamera, transition: .smoothMove, duration: 0.4,
            reason: "Show speaker and logo", displayID: 42,
            cameraX: 0.25, cameraY: 0.75, cameraWidth: 0.3,
            cameraShape: .roundedRectangle, cameraBackground: .blur,
            overlayID: overlayID, overlayVisible: false
        )
        let draft = OpenRouterAssistantDraft(
            reply: "Change the scene", titles: [], descriptions: [],
            newTakeWording: [], cuts: [], sceneChanges: [change]
        )

        XCTAssertNotNil(try draft.reviewedScene(context: context, timeline: timeline, revision: 1))
        let next = change.presentation(from: current)
        XCTAssertEqual(next.camera.centerX, 0.25, accuracy: 0.001)
        XCTAssertEqual(next.camera.centerY, 0.75, accuracy: 0.001)
        XCTAssertEqual(next.camera.width, 0.3, accuracy: 0.001)
        XCTAssertEqual(next.camera.shape, .roundedRectangle)
        XCTAssertEqual(next.resolvedCameraBackground.mode, .blur)
        XCTAssertFalse(try XCTUnwrap(next.resolvedImageOverlays.first).placement.isVisible)

        let unknownDisplay = OpenRouterAssistantDraft(
            reply: "Change the scene", titles: [], descriptions: [],
            newTakeWording: [], cuts: [], sceneChanges: [OpenRouterAssistantSceneChange(
                layout: .screenOnly, transition: .cut, duration: 0.15,
                reason: "Uncaptured display", displayID: 43
            )]
        )
        XCTAssertThrowsError(try unknownDisplay.reviewedScene(
            context: context, timeline: timeline, revision: 1
        ))
        let unknownImage = OpenRouterAssistantDraft(
            reply: "Show an image", titles: [], descriptions: [],
            newTakeWording: [], cuts: [], sceneChanges: [OpenRouterAssistantSceneChange(
                layout: .screenOnly, transition: .cut, duration: 0.15,
                reason: "Unknown image", overlayID: UUID(), overlayVisible: true
            )]
        )
        XCTAssertThrowsError(try unknownImage.reviewedScene(
            context: context, timeline: timeline, revision: 1
        ))
        let invalidPosition = OpenRouterAssistantSceneChange(
            layout: .cameraOnly, transition: .cut, duration: 0.15,
            reason: "Outside frame", cameraX: 1.5
        )
        XCTAssertFalse(invalidPosition.isValid)
    }

    func testCameraOnlySceneFillsFrameAndKeepsAudioIndependent() {
        let change = OpenRouterAssistantSceneChange(
            layout: .cameraOnly, transition: .cut, duration: 0.15, reason: "Speaker focus"
        )
        let presentation = change.presentation(from: .default)
        XCTAssertFalse(presentation.screen.isVisible)
        XCTAssertTrue(presentation.camera.isVisible)
        XCTAssertEqual(presentation.camera.width, 1)
        XCTAssertEqual(presentation.camera.height, 1)
        XCTAssertEqual(presentation.camera.shape, .rectangle)
        XCTAssertEqual(presentation.camera.centerX, 0.5)
        XCTAssertEqual(presentation.camera.centerY, 0.5)
    }
}
