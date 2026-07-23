import CryptoKit
import Foundation
import XCTest
@testable import StudioRecorder

final class YouTubeManagedStreamingTests: XCTestCase {
    func testPKCEUsesTheRFC7636S256Challenge() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

        XCTAssertEqual(
            GoogleOAuthPKCE.challenge(for: verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testOAuthCallbackRejectsWrongStateAndReturnsGoogleError() throws {
        XCTAssertThrowsError(try GoogleOAuthCallback.parse(
            URL(string: "http://127.0.0.1:49152/?code=secret&state=wrong")!,
            expectedState: "expected"
        ))
        XCTAssertThrowsError(try GoogleOAuthCallback.parse(
            URL(string: "http://127.0.0.1:49152/?error=access_denied&state=expected")!,
            expectedState: "expected"
        ))
    }

    func testExpiredOAuthTokenRefreshesWithoutLosingTheRefreshToken() async throws {
        let stored = GoogleOAuthToken(
            accessToken: "expired-access",
            refreshToken: "durable-refresh",
            expiresAt: Date(timeIntervalSince1970: 0),
            scope: "https://www.googleapis.com/auth/youtube",
            clientID: "desktop-client-id"
        )
        let tokens = MemoryGoogleOAuthTokens(token: stored)
        let transport = OAuthFakeTransport(
            response: #"{"access_token":"fresh-access","expires_in":3600,"scope":"https://www.googleapis.com/auth/youtube"}"#
        )
        let client = GoogleYouTubeOAuthClient(
            clientSecret: "desktop-client-secret",
            tokens: tokens,
            send: { request in try await transport.send(request) }
        )

        let accessToken = try await client.validAccessToken(clientID: "desktop-client-id")

        XCTAssertEqual(accessToken, "fresh-access")
        XCTAssertEqual(try tokens.load()?.refreshToken, "durable-refresh")
        XCTAssertTrue(try XCTUnwrap(tokens.load()).isFresh)
        let requests = await transport.requests()
        let request = try XCTUnwrap(requests.first)
        let form = URLComponents.percentEncodedQueryItems(from: request.httpBody)
        XCTAssertEqual(form["client_id"], "desktop-client-id")
        XCTAssertEqual(form["client_secret"], "desktop-client-secret")
        XCTAssertEqual(form["refresh_token"], "durable-refresh")
        let storedJSON = try XCTUnwrap(String(
            data: JSONEncoder().encode(try XCTUnwrap(tokens.load())),
            encoding: .utf8
        ))
        XCTAssertFalse(storedJSON.contains("desktop-client-secret"))
    }

    func testAuthorizationCodeExchangeIncludesTheDesktopClientSecret() {
        let form = GoogleOAuthTokenForm.authorizationCode(
            code: "authorization-code",
            clientID: "desktop-client-id",
            clientSecret: "desktop-client-secret",
            redirectURI: "http://127.0.0.1:49152",
            verifier: "pkce-verifier"
        )

        XCTAssertEqual(form.first(where: { $0.name == "client_secret" })?.value, "desktop-client-secret")
        XCTAssertEqual(form.first(where: { $0.name == "code_verifier" })?.value, "pkce-verifier")
    }

    func testFailedRevocationPreservesTheTokenForRetry() async throws {
        let stored = GoogleOAuthToken(
            accessToken: "access",
            refreshToken: "refresh-to-revoke",
            expiresAt: Date().addingTimeInterval(3_600),
            scope: "https://www.googleapis.com/auth/youtube",
            clientID: "desktop-client-id"
        )
        let tokens = MemoryGoogleOAuthTokens(token: stored)
        let client = GoogleYouTubeOAuthClient(
            clientSecret: "desktop-client-secret",
            tokens: tokens,
            send: { _ in throw URLError(.notConnectedToInternet) }
        )

        do {
            try await client.disconnect()
            XCTFail("Disconnect should surface a failed Google revocation.")
        } catch {
            XCTAssertNotNil(try tokens.load())
        }
    }

    func testLoopbackPageDoesNotClaimConnectionBeforeTokenExchange() {
        XCTAssertTrue(GoogleOAuthLoopbackReceiver.callbackHTML.contains("finishing the connection"))
        XCTAssertFalse(GoogleOAuthLoopbackReceiver.callbackHTML.contains("is connected to YouTube"))
    }

    func testCoordinatorReactivatesTheAppAfterAuthorizationSucceeds() async throws {
        let journal = YouTubeManagedSessionJournal(fileURL: temporaryJournalURL())
        let counter = await MainActor.run { ActivationCounter() }
        let coordinator = await MainActor.run {
            YouTubeManagedSessionCoordinator(
                oauth: authorizedOAuthClient(),
                journal: journal,
                apiSend: emptyBroadcastListResponse,
                connectOAuth: { _ in },
                activateApp: { counter.increment() }
            )
        }

        await coordinator.connect(clientID: "desktop-client-id")

        let isAuthorized = await coordinator.isAuthorized
        let activationCount = await counter.value
        XCTAssertTrue(isAuthorized)
        XCTAssertEqual(activationCount, 1)
        try await journal.clear()
    }

    func testCoordinatorReactivatesTheAppAndShowsRetryableErrorAfterAuthorizationFails() async throws {
        let journal = YouTubeManagedSessionJournal(fileURL: temporaryJournalURL())
        let counter = await MainActor.run { ActivationCounter() }
        let coordinator = await MainActor.run {
            YouTubeManagedSessionCoordinator(
                oauth: authorizedOAuthClient(),
                journal: journal,
                connectOAuth: { _ in throw GoogleOAuthError.authorizationDenied("access_denied") },
                activateApp: { counter.increment() }
            )
        }

        await coordinator.connect(clientID: "desktop-client-id")

        let activationCount = await counter.value
        let state = await coordinator.state
        XCTAssertEqual(activationCount, 1)
        XCTAssertEqual(state, .failed("Google authorization was cancelled. Try again."))
        try await journal.clear()
    }

    func testCoordinatorReactivatesOnceAfterTimeoutAndTokenFailure() async throws {
        let scenarios: [(GoogleOAuthError, YouTubeManagedSessionState)] = [
            (.authorizationTimedOut, .failed("Google authorization timed out. Try again.")),
            (.invalidResponse, .failed("Couldn’t connect YouTube. Try again.")),
        ]

        for (error, expectedState) in scenarios {
            let journal = YouTubeManagedSessionJournal(fileURL: temporaryJournalURL())
            let counter = await MainActor.run { ActivationCounter() }
            let coordinator = await MainActor.run {
                YouTubeManagedSessionCoordinator(
                    oauth: authorizedOAuthClient(),
                    journal: journal,
                    connectOAuth: { _ in throw error },
                    activateApp: { counter.increment() }
                )
            }

            await coordinator.connect(clientID: "desktop-client-id")

            let activationCount = await counter.value
            let state = await coordinator.state
            XCTAssertEqual(activationCount, 1)
            XCTAssertEqual(state, expectedState)
            try await journal.clear()
        }
    }

    func testOAuthTokenCannotBeReusedWithAnotherDesktopClient() async {
        let stored = GoogleOAuthToken(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3_600),
            scope: "https://www.googleapis.com/auth/youtube",
            clientID: "original-client"
        )
        let client = GoogleYouTubeOAuthClient(tokens: MemoryGoogleOAuthTokens(token: stored)) { _ in
            XCTFail("A mismatched client must reconnect instead of using or refreshing the token")
            throw URLError(.badServerResponse)
        }

        await XCTAssertThrowsErrorAsync(
            try await client.validAccessToken(clientID: "changed-client")
        ) { error in
            XCTAssertEqual(error as? GoogleOAuthError, .clientIDChanged)
        }
    }

    func testJournalPersistsRemoteIDsButNeverIngestionCredentials() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = directory.appending(path: "active-youtube-session.json")
        let journal = YouTubeManagedSessionJournal(fileURL: fileURL)
        let entry = YouTubeManagedSessionJournalEntry(
            broadcastID: "broadcast-id",
            streamID: "stream-id",
            title: "Studio Recorder Live",
            createdAt: Date(timeIntervalSince1970: 123),
            ownsBroadcast: false
        )

        try await journal.save(entry)

        let restored = try await journal.load()
        XCTAssertEqual(restored, entry)
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(contents.localizedCaseInsensitiveContains("streamKey"))
        XCTAssertFalse(contents.localizedCaseInsensitiveContains("streamName"))

        try await journal.clear()
        let cleared = try await journal.load()
        XCTAssertNil(cleared)
    }

    func testJournalDecodesEntriesCreatedBeforeRecoveryMetadataWasAdded() throws {
        let data = Data(#"{"broadcastID":"broadcast-id","streamID":"stream-id","title":"Legacy","createdAt":123}"#.utf8)

        let entry = try JSONDecoder().decode(YouTubeManagedSessionJournalEntry.self, from: data)

        XCTAssertNil(entry.localProjectID)
        XCTAssertNil(entry.deliveryMode)
        XCTAssertFalse(entry.autoStopEnabled)
        XCTAssertTrue(entry.ownsBroadcast)
        XCTAssertFalse(entry.cleanStopRequested)
    }

    func testLifecycleWaitsForIngestionBeforeTestingThenGoesLive() {
        XCTAssertEqual(
            YouTubeManagedLifecycle.nextAction(broadcastStatus: .ready, streamStatus: .inactive),
            .waitForIngestion
        )
        XCTAssertEqual(
            YouTubeManagedLifecycle.nextAction(broadcastStatus: .ready, streamStatus: .active),
            .transitionToTesting
        )
        XCTAssertEqual(
            YouTubeManagedLifecycle.nextAction(broadcastStatus: .testing, streamStatus: .active),
            .transitionToLive
        )
        XCTAssertEqual(
            YouTubeManagedLifecycle.nextAction(broadcastStatus: .live, streamStatus: .active),
            .monitor
        )
        XCTAssertEqual(
            YouTubeManagedLifecycle.nextAction(broadcastStatus: .complete, streamStatus: .inactive),
            .finished
        )
    }

    func testAPIClientCreatesPrivateBroadcastAndRTMPSStreamThenBindsThem() async throws {
        let transport = YouTubeAPIFakeTransport(responses: [
            #"{"id":"broadcast-id","status":{"lifeCycleStatus":"ready"}}"#,
            #"{"id":"stream-id","cdn":{"ingestionInfo":{"rtmpsIngestionAddress":"rtmps://a.rtmps.youtube.com/live2","streamName":"secret-key"}},"status":{"streamStatus":"ready","healthStatus":{"status":"noData","configurationIssues":[]}}}"#,
            #"{"id":"broadcast-id","status":{"lifeCycleStatus":"ready"},"contentDetails":{"boundStreamId":"stream-id"}}"#,
        ])
        let client = YouTubeLiveAPIClient(
            accessToken: { "access-token" },
            send: { request in try await transport.send(request) }
        )

        let broadcast = try await client.createBroadcast(
            title: "Studio Recorder Live",
            scheduledStartTime: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let stream = try await client.createStream(title: "Studio Recorder Live")
        _ = try await client.bind(broadcastID: broadcast.id, streamID: stream.id)

        XCTAssertEqual(broadcast.id, "broadcast-id")
        XCTAssertEqual(stream.id, "stream-id")
        XCTAssertEqual(stream.ingestion?.serverURL.absoluteString, "rtmps://a.rtmps.youtube.com/live2")
        XCTAssertEqual(stream.ingestion?.streamKey, "secret-key")
        let requests = await transport.requests()
        XCTAssertEqual(requests.map(\.url?.path), [
            "/youtube/v3/liveBroadcasts",
            "/youtube/v3/liveStreams",
            "/youtube/v3/liveBroadcasts/bind",
        ])
        let broadcastBody = try XCTUnwrap(requests.first?.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: broadcastBody) as? [String: Any])
        let status = try XCTUnwrap(object["status"] as? [String: Any])
        XCTAssertEqual(status["privacyStatus"] as? String, "private")
    }

    func testAPIClientListsUpcomingBroadcastsWithTheirBoundStreams() async throws {
        let transport = YouTubeAPIFakeTransport(responses: [
            #"{"items":[{"id":"later","snippet":{"title":"Later","scheduledStartTime":"2026-07-23T18:00:00Z"},"status":{"lifeCycleStatus":"ready","privacyStatus":"public"},"contentDetails":{"boundStreamId":"stream-later"}},{"id":"next","snippet":{"title":"Next","scheduledStartTime":"2026-07-22T18:00:00Z"},"status":{"lifeCycleStatus":"ready","privacyStatus":"unlisted"},"contentDetails":{}}]}"#,
        ])
        let client = YouTubeLiveAPIClient(
            accessToken: { "access-token" },
            send: { request in try await transport.send(request) }
        )

        let broadcasts = try await client.upcomingBroadcasts()

        XCTAssertEqual(broadcasts.map(\.id), ["next", "later"])
        XCTAssertEqual(broadcasts.first?.privacyStatus, "unlisted")
        XCTAssertNil(broadcasts.first?.boundStreamID)
        XCTAssertEqual(broadcasts.last?.boundStreamID, "stream-later")
        let requests = await transport.requests()
        let request = try XCTUnwrap(requests.first)
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "broadcastStatus" })?.value, "upcoming")
        XCTAssertEqual(query?.first(where: { $0.name == "broadcastType" })?.value, "event")
    }

    func testUnstartedBroadcastIsDeletedInsteadOfTransitionedToComplete() async throws {
        let transport = YouTubeAPIFakeTransport(responses: ["{}"])
        let client = YouTubeLiveAPIClient(
            accessToken: { "access-token" },
            send: { request in try await transport.send(request) }
        )

        try await client.deleteBroadcast(id: "broadcast-id")

        let requests = await transport.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/youtube/v3/liveBroadcasts")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "id" })?.value, "broadcast-id")
    }

    func testAPIClientRefreshesIngestionAndSurfacesServerHealthIssues() async throws {
        let transport = YouTubeAPIFakeTransport(responses: [
            #"{"items":[{"id":"stream-id","cdn":{"ingestionInfo":{"rtmpsIngestionAddress":"rtmps://b.rtmps.youtube.com/live2","rtmpsBackupIngestionAddress":"rtmps://c.rtmps.youtube.com/live2","streamName":"rotated-key"}},"status":{"streamStatus":"active","healthStatus":{"status":"bad","configurationIssues":[{"type":"noAudioStream","severity":"error","reason":"No audio"}]}}}]}"#,
        ])
        let client = YouTubeLiveAPIClient(
            accessToken: { "access-token" },
            send: { request in try await transport.send(request) }
        )

        let stream = try await client.stream(id: "stream-id")

        XCTAssertEqual(stream.ingestion?.streamKey, "rotated-key")
        XCTAssertEqual(stream.ingestion?.backupServerURL?.absoluteString, "rtmps://c.rtmps.youtube.com/live2")
        XCTAssertEqual(stream.status, .active)
        XCTAssertEqual(stream.health.status, .bad)
        XCTAssertEqual(stream.health.issues.first?.type, "noAudioStream")
    }

    func testAPIClientCompletesTheRemoteBroadcast() async throws {
        let transport = YouTubeAPIFakeTransport(responses: [
            #"{"id":"broadcast-id","status":{"lifeCycleStatus":"complete"}}"#,
        ])
        let client = YouTubeLiveAPIClient(
            accessToken: { "access-token" },
            send: { request in try await transport.send(request) }
        )

        _ = try await client.transition(broadcastID: "broadcast-id", to: .complete)

        let requests = await transport.requests()
        let request = try XCTUnwrap(requests.first)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "broadcastStatus" })?.value, "complete")
    }

    func testCoordinatorUsesTheBoundStreamForASelectedBroadcast() async throws {
        let transport = YouTubeAPIFakeTransport(responses: [
            #"{"items":[{"id":"broadcast-id","snippet":{"title":"Scheduled Show","scheduledStartTime":"2026-07-23T18:00:00Z"},"status":{"lifeCycleStatus":"ready","privacyStatus":"unlisted"},"contentDetails":{"boundStreamId":"bound-stream"}}]}"#,
            #"{"items":[{"id":"broadcast-id","snippet":{"title":"Scheduled Show","scheduledStartTime":"2026-07-23T18:00:00Z"},"status":{"lifeCycleStatus":"ready","privacyStatus":"unlisted"},"contentDetails":{"boundStreamId":"bound-stream"}}]}"#,
            #"{"items":[{"id":"bound-stream","cdn":{"ingestionInfo":{"rtmpsIngestionAddress":"rtmps://a.rtmps.youtube.com/live2","streamName":"bound-key"}},"status":{"streamStatus":"ready","healthStatus":{"status":"noData","configurationIssues":[]}}}]}"#,
        ])
        let journal = YouTubeManagedSessionJournal(fileURL: temporaryJournalURL())
        let coordinator = await MainActor.run {
            YouTubeManagedSessionCoordinator(
                oauth: authorizedOAuthClient(),
                journal: journal,
                apiSend: { request in try await transport.send(request) }
            )
        }
        await coordinator.restore()
        await coordinator.refreshUpcomingBroadcasts(clientID: "desktop-client-id")
        await MainActor.run { coordinator.selectedBroadcastID = "broadcast-id" }

        let configuration = try await coordinator.prepareConfiguration(
            clientID: "desktop-client-id",
            canvasSize: CGSize(width: 1_920, height: 1_080),
            frameRate: 30,
            videoBitRate: 10_000_000,
            audioBitRate: 128_000
        )

        XCTAssertEqual(configuration.streamKey, "bound-key")
        let requests = await transport.requests()
        XCTAssertEqual(requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }, [
            "GET /youtube/v3/liveBroadcasts",
            "GET /youtube/v3/liveBroadcasts",
            "GET /youtube/v3/liveStreams",
        ])
        try await journal.clear()
    }

    func testCoordinatorCreatesAndBindsAStreamWhenSelectedBroadcastHasNone() async throws {
        let transport = YouTubeAPIFakeTransport(responses: [
            #"{"items":[{"id":"broadcast-id","snippet":{"title":"Scheduled Show","scheduledStartTime":"2026-07-23T18:00:00Z"},"status":{"lifeCycleStatus":"ready","privacyStatus":"public"},"contentDetails":{}}]}"#,
            #"{"id":"new-stream","cdn":{"ingestionInfo":{"rtmpsIngestionAddress":"rtmps://a.rtmps.youtube.com/live2","streamName":"new-key"}},"status":{"streamStatus":"ready","healthStatus":{"status":"noData","configurationIssues":[]}}}"#,
            #"{"id":"broadcast-id","status":{"lifeCycleStatus":"ready"},"contentDetails":{"boundStreamId":"new-stream"}}"#,
        ])
        let journal = YouTubeManagedSessionJournal(fileURL: temporaryJournalURL())
        let coordinator = await MainActor.run {
            YouTubeManagedSessionCoordinator(
                oauth: authorizedOAuthClient(),
                journal: journal,
                apiSend: { request in try await transport.send(request) }
            )
        }
        await coordinator.restore()
        await MainActor.run { coordinator.selectedBroadcastID = "broadcast-id" }

        let configuration = try await coordinator.prepareConfiguration(
            clientID: "desktop-client-id",
            canvasSize: CGSize(width: 1_920, height: 1_080),
            frameRate: 30,
            videoBitRate: 10_000_000,
            audioBitRate: 128_000
        )

        XCTAssertEqual(configuration.streamKey, "new-key")
        let requests = await transport.requests()
        XCTAssertEqual(requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }, [
            "GET /youtube/v3/liveBroadcasts",
            "POST /youtube/v3/liveStreams",
            "POST /youtube/v3/liveBroadcasts/bind",
        ])
        try await journal.clear()
    }

    func testStoppingAnUnstartedSelectedBroadcastPreservesTheYouTubeEvent() async throws {
        let journal = YouTubeManagedSessionJournal(fileURL: temporaryJournalURL())
        try await journal.save(YouTubeManagedSessionJournalEntry(
            broadcastID: "broadcast-id",
            streamID: "stream-id",
            title: "Scheduled Show",
            createdAt: Date(),
            ownsBroadcast: false
        ))
        let transport = YouTubeAPIFakeTransport(responses: [
            #"{"items":[{"id":"broadcast-id","snippet":{"title":"Scheduled Show","scheduledStartTime":"2026-07-23T18:00:00Z"},"status":{"lifeCycleStatus":"ready","privacyStatus":"unlisted"},"contentDetails":{"boundStreamId":"stream-id"}}]}"#,
            #"{"items":[{"id":"broadcast-id","snippet":{"title":"Scheduled Show","scheduledStartTime":"2026-07-23T18:00:00Z"},"status":{"lifeCycleStatus":"ready","privacyStatus":"unlisted"},"contentDetails":{"boundStreamId":"stream-id"}}]}"#,
        ])
        let coordinator = await MainActor.run {
            YouTubeManagedSessionCoordinator(
                oauth: authorizedOAuthClient(),
                journal: journal,
                apiSend: { request in try await transport.send(request) }
            )
        }
        await coordinator.restore()

        await coordinator.complete(clientID: "desktop-client-id")

        let requests = await transport.requests()
        XCTAssertEqual(requests.compactMap(\.httpMethod), ["GET", "GET"])
        XCTAssertFalse(requests.contains(where: { $0.httpMethod == "DELETE" }))
        let restored = try await journal.load()
        XCTAssertNil(restored)
    }

    func testPipelineRefreshesManagedIngestionBeforeRetrying() async throws {
        let sink = ConfigurationRecordingSink()
        let pipeline = LiveProgramPipeline(
            sink: sink,
            reconnectPolicy: LiveStreamReconnectPolicy(
                maximumAttempts: 1,
                baseDelaySeconds: 0,
                maximumDelaySeconds: 0
            )
        )
        let initial = YouTubeStreamConfiguration(
            serverURL: URL(string: "rtmps://a.rtmps.youtube.com/live2")!,
            streamKey: "old-key",
            canvasSize: CGSize(width: 640, height: 360),
            frameRate: 30,
            videoBitRate: 3_000_000
        )
        let refreshed = YouTubeStreamConfiguration(
            serverURL: URL(string: "rtmps://b.rtmps.youtube.com/live2")!,
            streamKey: "new-key",
            canvasSize: CGSize(width: 640, height: 360),
            frameRate: 30,
            videoBitRate: 3_000_000
        )

        try await pipeline.start(
            configuration: initial,
            presentation: .default,
            audioConfiguration: LiveStreamAudioConfiguration(
                capturesSystemAudio: false,
                capturesMicrophone: false,
                microphoneDeviceID: nil,
                excludesStudioRecorderAudio: true
            ),
            configurationProvider: { refreshed }
        ) { _ in }

        let configurations = await sink.configurations()
        XCTAssertEqual(configurations, [initial, refreshed])
        await pipeline.stop()
    }
}

private func temporaryJournalURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        .appending(path: "active-youtube-session.json")
}

private func authorizedOAuthClient() -> GoogleYouTubeOAuthClient {
    GoogleYouTubeOAuthClient(tokens: MemoryGoogleOAuthTokens(token: GoogleOAuthToken(
        accessToken: "access-token",
        refreshToken: "refresh-token",
        expiresAt: Date().addingTimeInterval(3_600),
        scope: "https://www.googleapis.com/auth/youtube",
        clientID: "desktop-client-id"
    ))) { _ in
        throw URLError(.badServerResponse)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

private actor YouTubeAPIFakeTransport {
    private var queued: [String]
    private var seen: [URLRequest] = []

    init(responses: [String]) {
        queued = responses
    }

    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        seen.append(request)
        guard !queued.isEmpty else { throw URLError(.badServerResponse) }
        let body = queued.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(body.utf8), response)
    }

    func requests() -> [URLRequest] { seen }
}

private actor OAuthFakeTransport {
    private let responseBody: String
    private var seen: [URLRequest] = []

    init(response: String) {
        responseBody = response
    }

    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        seen.append(request)
        return (
            Data(responseBody.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }

    func requests() -> [URLRequest] { seen }
}

@MainActor
private final class ActivationCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private func emptyBroadcastListResponse(_ request: URLRequest) async throws -> (Data, URLResponse) {
    (
        Data(#"{"items":[]}"#.utf8),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    )
}

private extension URLComponents {
    static func percentEncodedQueryItems(from body: Data?) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = body.flatMap { String(data: $0, encoding: .utf8) }
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
    }
}

private actor ConfigurationRecordingSink: LiveProgramSink {
    private var seen: [YouTubeStreamConfiguration] = []

    func connect(
        configuration: YouTubeStreamConfiguration,
        audioConfiguration: LiveStreamAudioConfiguration,
        eventHandler: @escaping LiveProgramSinkEventHandler
    ) async throws {
        seen.append(configuration)
        if seen.count == 1 { throw URLError(.cannotConnectToHost) }
        await eventHandler(.connected)
    }

    func appendVideo(_ sampleBuffer: SendableSampleBuffer) {}
    func appendAudio(_ sampleBuffer: SendableSampleBuffer, track: UInt8) {}
    func disconnect() {}
    func configurations() -> [YouTubeStreamConfiguration] { seen }
}

private final class MemoryGoogleOAuthTokens: GoogleOAuthTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: GoogleOAuthToken?

    init(token: GoogleOAuthToken? = nil) {
        self.token = token
    }

    func load() throws -> GoogleOAuthToken? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    func save(_ token: GoogleOAuthToken) throws {
        lock.lock()
        self.token = token
        lock.unlock()
    }

    func delete() throws {
        lock.lock()
        token = nil
        lock.unlock()
    }
}
