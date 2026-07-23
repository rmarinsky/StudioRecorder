import CryptoKit
import Foundation
import Security

enum GoogleOAuthPKCE {
    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    static func randomVerifier(byteCount: Int = 48) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw StreamCredentialError.keychain(status) }
        return Data(bytes).base64URLEncodedString()
    }
}

enum GoogleOAuthCallback {
    static func parse(_ url: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.first(where: { $0.name == "state" })?.value == expectedState else {
            throw GoogleOAuthError.invalidState
        }
        if let error = components.queryItems?.first(where: { $0.name == "error" })?.value {
            throw GoogleOAuthError.authorizationDenied(error)
        }
        guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else {
            throw GoogleOAuthError.missingAuthorizationCode
        }
        return code
    }
}

enum GoogleOAuthError: LocalizedError, Equatable {
    case invalidState
    case authorizationDenied(String)
    case missingAuthorizationCode
    case missingClientID
    case missingClientSecret
    case invalidResponse
    case authorizationTimedOut
    case clientIDChanged

    var errorDescription: String? {
        switch self {
        case .invalidState: "Google returned an OAuth response with an invalid state."
        case .authorizationDenied(let reason): "Google authorization failed: \(reason)."
        case .missingAuthorizationCode: "Google did not return an authorization code."
        case .missingClientID: "YouTube connection is not configured in this build."
        case .missingClientSecret: "YouTube connection is not configured in this build."
        case .invalidResponse: "Google returned an invalid OAuth response."
        case .authorizationTimedOut: "Google authorization timed out. Connect again to retry."
        case .clientIDChanged: "The Google OAuth client ID changed. Disconnect and connect YouTube again."
        }
    }
}

struct YouTubeManagedSessionJournalEntry: Codable, Equatable, Sendable {
    let broadcastID: String
    var streamID: String?
    let title: String
    let createdAt: Date
    var localProjectID: UUID?
    let deliveryMode: StreamDeliveryMode?
    let autoStopEnabled: Bool
    let ownsBroadcast: Bool
    var cleanStopRequested: Bool

    init(
        broadcastID: String,
        streamID: String?,
        title: String,
        createdAt: Date,
        localProjectID: UUID? = nil,
        deliveryMode: StreamDeliveryMode? = nil,
        autoStopEnabled: Bool = false,
        ownsBroadcast: Bool = true,
        cleanStopRequested: Bool = false
    ) {
        self.broadcastID = broadcastID
        self.streamID = streamID
        self.title = title
        self.createdAt = createdAt
        self.localProjectID = localProjectID
        self.deliveryMode = deliveryMode
        self.autoStopEnabled = autoStopEnabled
        self.ownsBroadcast = ownsBroadcast
        self.cleanStopRequested = cleanStopRequested
    }

    private enum CodingKeys: String, CodingKey {
        case broadcastID, streamID, title, createdAt, localProjectID, deliveryMode, autoStopEnabled, ownsBroadcast, cleanStopRequested
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        broadcastID = try container.decode(String.self, forKey: .broadcastID)
        streamID = try container.decodeIfPresent(String.self, forKey: .streamID)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        localProjectID = try container.decodeIfPresent(UUID.self, forKey: .localProjectID)
        deliveryMode = try container.decodeIfPresent(StreamDeliveryMode.self, forKey: .deliveryMode)
        autoStopEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoStopEnabled) ?? false
        ownsBroadcast = try container.decodeIfPresent(Bool.self, forKey: .ownsBroadcast) ?? true
        cleanStopRequested = try container.decodeIfPresent(Bool.self, forKey: .cleanStopRequested) ?? false
    }
}

actor YouTubeManagedSessionJournal {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.fileURL = support
                .appending(path: "StudioRecorder", directoryHint: .isDirectory)
                .appending(path: "active-youtube-session.json")
        }
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() throws -> YouTubeManagedSessionJournalEntry? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try decoder.decode(
            YouTubeManagedSessionJournalEntry.self,
            from: Data(contentsOf: fileURL)
        )
    }

    func save(_ entry: YouTubeManagedSessionJournalEntry) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(entry).write(to: fileURL, options: .atomic)
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

enum YouTubeBroadcastStatus: String, Codable, Equatable, Sendable {
    case created
    case ready
    case testStarting
    case testing
    case liveStarting
    case live
    case complete
    case revoked
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

enum YouTubeRemoteStreamStatus: String, Codable, Equatable, Sendable {
    case created
    case ready
    case active
    case inactive
    case error
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

enum YouTubeRemoteHealthStatus: String, Codable, Equatable, Sendable {
    case good
    case ok
    case bad
    case noData
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

struct YouTubeHealthIssue: Codable, Equatable, Sendable {
    let type: String
    let severity: String?
    let reason: String?
    let description: String?
}

struct YouTubeRemoteHealth: Codable, Equatable, Sendable {
    let status: YouTubeRemoteHealthStatus
    let configurationIssues: [YouTubeHealthIssue]?

    var issues: [YouTubeHealthIssue] { configurationIssues ?? [] }

    static let noData = YouTubeRemoteHealth(status: .noData, configurationIssues: [])
}

struct YouTubeIngestion: Equatable, Sendable {
    let serverURL: URL
    let backupServerURL: URL?
    let streamKey: String
}

struct YouTubeRemoteStream: Equatable, Sendable {
    let id: String
    let ingestion: YouTubeIngestion?
    let status: YouTubeRemoteStreamStatus
    let health: YouTubeRemoteHealth
}

struct YouTubeScheduledBroadcast: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let scheduledStartTime: Date
    let privacyStatus: String
    let boundStreamID: String?
}

enum YouTubeManagedLifecycleAction: Equatable, Sendable {
    case waitForIngestion
    case transitionToTesting
    case waitForTesting
    case transitionToLive
    case waitForLive
    case monitor
    case finished
    case failed
}

enum YouTubeManagedLifecycle {
    static func nextAction(
        broadcastStatus: YouTubeBroadcastStatus,
        streamStatus: YouTubeRemoteStreamStatus
    ) -> YouTubeManagedLifecycleAction {
        if broadcastStatus == .complete { return .finished }
        if broadcastStatus == .revoked || streamStatus == .error { return .failed }
        if streamStatus != .active { return .waitForIngestion }
        return switch broadcastStatus {
        case .created, .ready: .transitionToTesting
        case .testStarting: .waitForTesting
        case .testing: .transitionToLive
        case .liveStarting: .waitForLive
        case .live: .monitor
        case .complete: .finished
        case .revoked, .unknown: .failed
        }
    }
}

actor YouTubeLiveAPIClient {
    typealias AccessToken = @Sendable () async throws -> String
    typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let accessToken: AccessToken
    private let send: Send
    private let baseURL: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(
        baseURL: URL = URL(string: "https://www.googleapis.com/youtube/v3")!,
        accessToken: @escaping AccessToken,
        send: @escaping Send = { try await URLSession.shared.data(for: $0) }
    ) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.send = send
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func upcomingBroadcasts() async throws -> [YouTubeScheduledBroadcast] {
        let response: BroadcastListResponse = try await retryingListRequest {
            try await self.request(
                path: "liveBroadcasts",
                method: "GET",
                query: [
                    URLQueryItem(name: "broadcastStatus", value: "upcoming"),
                    URLQueryItem(name: "broadcastType", value: "event"),
                    URLQueryItem(name: "maxResults", value: "50"),
                    URLQueryItem(name: "part", value: "id,snippet,status,contentDetails"),
                ],
                body: Optional<EmptyBody>.none,
                response: BroadcastListResponse.self
            )
        }
        return response.items.compactMap { resource in
            guard let snippet = resource.snippet else { return nil }
            return YouTubeScheduledBroadcast(
                id: resource.id,
                title: snippet.title,
                scheduledStartTime: snippet.scheduledStartTime,
                privacyStatus: resource.status?.privacyStatus ?? "private",
                boundStreamID: resource.contentDetails?.boundStreamId
            )
        }
        .sorted { $0.scheduledStartTime < $1.scheduledStartTime }
    }

    func createBroadcast(title: String, scheduledStartTime: Date) async throws -> BroadcastResource {
        let body = BroadcastInsertBody(
            snippet: .init(title: title, scheduledStartTime: scheduledStartTime),
            status: .init(privacyStatus: "private", selfDeclaredMadeForKids: false),
            contentDetails: .init(
                enableAutoStart: false,
                enableAutoStop: false,
                enableDvr: true,
                recordFromStart: true,
                monitorStream: .init(enableMonitorStream: true)
            )
        )
        return try await request(
            path: "liveBroadcasts",
            method: "POST",
            query: [URLQueryItem(name: "part", value: "id,snippet,status,contentDetails")],
            body: body,
            response: BroadcastResource.self
        )
    }

    func createStream(title: String) async throws -> YouTubeRemoteStream {
        let body = StreamInsertBody(
            snippet: .init(title: title),
            cdn: .init(frameRate: "variable", ingestionType: "rtmp", resolution: "variable"),
            contentDetails: .init(isReusable: false)
        )
        let resource: StreamResource = try await request(
            path: "liveStreams",
            method: "POST",
            query: [URLQueryItem(name: "part", value: "id,snippet,cdn,status,contentDetails")],
            body: body,
            response: StreamResource.self
        )
        return try resource.remoteStream()
    }

    func bind(broadcastID: String, streamID: String) async throws -> BroadcastResource {
        try await request(
            path: "liveBroadcasts/bind",
            method: "POST",
            query: [
                URLQueryItem(name: "id", value: broadcastID),
                URLQueryItem(name: "streamId", value: streamID),
                URLQueryItem(name: "part", value: "id,status,contentDetails"),
            ],
            body: Optional<EmptyBody>.none,
            response: BroadcastResource.self
        )
    }

    func stream(id: String) async throws -> YouTubeRemoteStream {
        let response: StreamListResponse = try await retryingListRequest {
            try await self.request(
                path: "liveStreams",
                method: "GET",
                query: [
                    URLQueryItem(name: "id", value: id),
                    URLQueryItem(name: "part", value: "id,cdn,status"),
                ],
                body: Optional<EmptyBody>.none,
                response: StreamListResponse.self
            )
        }
        guard let resource = response.items.first else { throw YouTubeAPIError.resourceNotFound }
        return try resource.remoteStream()
    }

    func broadcast(id: String) async throws -> BroadcastResource {
        let response: BroadcastListResponse = try await retryingListRequest {
            try await self.request(
                path: "liveBroadcasts",
                method: "GET",
                query: [
                    URLQueryItem(name: "id", value: id),
                    URLQueryItem(name: "part", value: "id,status,contentDetails,snippet"),
                ],
                body: Optional<EmptyBody>.none,
                response: BroadcastListResponse.self
            )
        }
        guard let resource = response.items.first else { throw YouTubeAPIError.resourceNotFound }
        return resource
    }

    @discardableResult
    func transition(broadcastID: String, to status: YouTubeBroadcastStatus) async throws -> BroadcastResource {
        try await request(
            path: "liveBroadcasts/transition",
            method: "POST",
            query: [
                URLQueryItem(name: "id", value: broadcastID),
                URLQueryItem(name: "broadcastStatus", value: status.rawValue),
                URLQueryItem(name: "part", value: "id,status,contentDetails"),
            ],
            body: Optional<EmptyBody>.none,
            response: BroadcastResource.self
        )
    }

    func deleteBroadcast(id: String) async throws {
        let _: EmptyResponse = try await request(
            path: "liveBroadcasts",
            method: "DELETE",
            query: [URLQueryItem(name: "id", value: id)],
            body: Optional<EmptyBody>.none,
            response: EmptyResponse.self
        )
    }

    private func retryingListRequest<Response>(
        _ operation: () async throws -> Response
    ) async throws -> Response {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                return try await operation()
            } catch {
                guard isRetryableListError(error), attempt < 2 else { throw error }
                lastError = error
                try await Task.sleep(for: .milliseconds(Int.random(in: 200...800) * (attempt + 1)))
            }
        }
        throw lastError ?? YouTubeAPIError.invalidResponse
    }

    private func isRetryableListError(_ error: Error) -> Bool {
        if error is URLError { return true }
        guard let apiError = error as? YouTubeAPIError,
              case .requestFailed(let status, _) = apiError else { return false }
        return status == 408 || status == 429 || status >= 500
    }

    private func request<Body: Encodable, Response: Decodable>(
        path: String,
        method: String,
        query: [URLQueryItem],
        body: Body?,
        response: Response.Type
    ) async throws -> Response {
        var components = URLComponents(
            url: baseURL.appending(path: path),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, urlResponse) = try await send(request)
        guard let http = urlResponse as? HTTPURLResponse else { throw YouTubeAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? decoder.decode(GoogleAPIErrorEnvelope.self, from: data).error.message)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw YouTubeAPIError.requestFailed(status: http.statusCode, detail: detail)
        }
        if data.isEmpty, let empty = EmptyResponse() as? Response {
            return empty
        }
        do {
            return try decoder.decode(response, from: data)
        } catch {
            throw YouTubeAPIError.invalidResponse
        }
    }
}

extension YouTubeLiveAPIClient {
    struct BroadcastResource: Decodable, Equatable, Sendable {
        let id: String
        let snippet: Snippet?
        let status: BroadcastStatusBody?
        let contentDetails: ContentDetails?

        struct Snippet: Decodable, Equatable, Sendable {
            let title: String
            let scheduledStartTime: Date
        }

        struct BroadcastStatusBody: Decodable, Equatable, Sendable {
            let lifeCycleStatus: YouTubeBroadcastStatus?
            let privacyStatus: String?
        }

        struct ContentDetails: Decodable, Equatable, Sendable {
            let boundStreamId: String?
        }
    }
}

private struct BroadcastListResponse: Decodable { let items: [YouTubeLiveAPIClient.BroadcastResource] }

private struct StreamListResponse: Decodable { let items: [StreamResource] }

private struct StreamResource: Decodable {
    let id: String
    let cdn: CDN?
    let status: Status?

    struct CDN: Decodable {
        let ingestionInfo: IngestionInfo?
    }

    struct IngestionInfo: Decodable {
        let rtmpsIngestionAddress: String?
        let rtmpsBackupIngestionAddress: String?
        let streamName: String?
    }

    struct Status: Decodable {
        let streamStatus: YouTubeRemoteStreamStatus?
        let healthStatus: YouTubeRemoteHealth?
    }

    func remoteStream() throws -> YouTubeRemoteStream {
        let ingestion: YouTubeIngestion?
        if let address = cdn?.ingestionInfo?.rtmpsIngestionAddress,
           let serverURL = URL(string: address),
           let key = cdn?.ingestionInfo?.streamName,
           !key.isEmpty {
            ingestion = YouTubeIngestion(
                serverURL: serverURL,
                backupServerURL: cdn?.ingestionInfo?.rtmpsBackupIngestionAddress.flatMap(URL.init(string:)),
                streamKey: key
            )
        } else {
            ingestion = nil
        }
        return YouTubeRemoteStream(
            id: id,
            ingestion: ingestion,
            status: status?.streamStatus ?? .unknown,
            health: status?.healthStatus ?? .noData
        )
    }
}

private struct BroadcastInsertBody: Encodable {
    let snippet: Snippet
    let status: Status
    let contentDetails: ContentDetails

    struct Snippet: Encodable { let title: String; let scheduledStartTime: Date }
    struct Status: Encodable { let privacyStatus: String; let selfDeclaredMadeForKids: Bool }
    struct ContentDetails: Encodable {
        let enableAutoStart: Bool
        let enableAutoStop: Bool
        let enableDvr: Bool
        let recordFromStart: Bool
        let monitorStream: MonitorStream
    }
    struct MonitorStream: Encodable { let enableMonitorStream: Bool }
}

private struct StreamInsertBody: Encodable {
    let snippet: Snippet
    let cdn: CDN
    let contentDetails: ContentDetails

    struct Snippet: Encodable { let title: String }
    struct CDN: Encodable { let frameRate: String; let ingestionType: String; let resolution: String }
    struct ContentDetails: Encodable { let isReusable: Bool }
}

private struct EmptyBody: Encodable {}
private struct EmptyResponse: Decodable {}

private struct GoogleAPIErrorEnvelope: Decodable {
    let error: Detail
    struct Detail: Decodable { let message: String }
}

enum YouTubeAPIError: LocalizedError, Equatable {
    case invalidResponse
    case missingIngestion
    case resourceNotFound
    case requestFailed(status: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "YouTube returned an invalid API response."
        case .missingIngestion: "YouTube did not return an RTMPS ingestion address and stream key."
        case .resourceNotFound: "The managed YouTube live resource no longer exists."
        case .requestFailed(_, let detail): "YouTube API: \(detail)"
        }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
