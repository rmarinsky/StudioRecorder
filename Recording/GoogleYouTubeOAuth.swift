import AppKit
import Foundation
import Network
import Security

struct GoogleOAuthToken: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let scope: String
    let clientID: String

    var isFresh: Bool { expiresAt.timeIntervalSinceNow > 60 }
}

protocol GoogleOAuthTokenStoring: Sendable {
    func load() throws -> GoogleOAuthToken?
    func save(_ token: GoogleOAuthToken) throws
    func delete() throws
}

struct KeychainGoogleOAuthTokenStore: GoogleOAuthTokenStoring {
    private let service: String
    private let account: String

    init(
        service: String = "ua.com.rmarinsky.studiorecorder.youtube",
        account: String = "google-oauth-token"
    ) {
        self.service = service
        self.account = account
    }

    func load() throws -> GoogleOAuthToken? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StreamCredentialError.keychain(status) }
        guard let data = result as? Data else { return nil }
        return try JSONDecoder().decode(GoogleOAuthToken.self, from: data)
    }

    func save(_ token: GoogleOAuthToken) throws {
        let data = try JSONEncoder().encode(token)
        let status = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw StreamCredentialError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw StreamCredentialError.keychain(status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StreamCredentialError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

actor GoogleYouTubeOAuthClient {
    private static let scope = "https://www.googleapis.com/auth/youtube"
    private let clientSecret: String
    private let tokens: any GoogleOAuthTokenStoring
    private let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private var cachedToken: GoogleOAuthToken?

    init(
        clientSecret: String? = nil,
        bundle: Bundle = .main,
        tokens: any GoogleOAuthTokenStoring = KeychainGoogleOAuthTokenStore(),
        send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
            try await URLSession.shared.data(for: $0)
        }
    ) {
        self.clientSecret = (clientSecret
            ?? (bundle.object(forInfoDictionaryKey: "GoogleOAuthClientSecret") as? String)
            ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.tokens = tokens
        self.send = send
        cachedToken = try? tokens.load()
    }

    func hasStoredAuthorization() -> Bool {
        cachedToken != nil
    }

    func connect(clientID rawClientID: String) async throws {
        let clientID = rawClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw GoogleOAuthError.missingClientID }
        guard !clientSecret.isEmpty else { throw GoogleOAuthError.missingClientSecret }
        let verifier = try GoogleOAuthPKCE.randomVerifier()
        let state = try GoogleOAuthPKCE.randomVerifier(byteCount: 24)
        let events = try GoogleOAuthLoopbackReceiver.events()
        var iterator = events.makeAsyncIterator()
        guard case .ready(let port) = try await iterator.next() else {
            throw GoogleOAuthError.invalidResponse
        }
        let redirectURI = "http://127.0.0.1:\(port)"
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "code_challenge", value: GoogleOAuthPKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authorizationURL = components.url else { throw GoogleOAuthError.invalidResponse }
        let opened = await MainActor.run { NSWorkspace.shared.open(authorizationURL) }
        guard opened else { throw GoogleOAuthError.authorizationDenied("the browser could not be opened") }

        while let event = try await iterator.next() {
            guard case .callback(let callbackURL) = event else { continue }
            let code = try GoogleOAuthCallback.parse(callbackURL, expectedState: state)
            let token = try await exchangeCode(
                code,
                clientID: clientID,
                redirectURI: redirectURI,
                verifier: verifier
            )
            try tokens.save(token)
            cachedToken = token
            return
        }
        throw GoogleOAuthError.invalidResponse
    }

    func validAccessToken(clientID rawClientID: String) async throws -> String {
        let clientID = rawClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw GoogleOAuthError.missingClientID }
        var token = cachedToken
        if token == nil { token = try tokens.load() }
        guard let token else { throw GoogleOAuthError.authorizationDenied("connect YouTube first") }
        guard token.clientID == clientID else { throw GoogleOAuthError.clientIDChanged }
        if token.isFresh {
            cachedToken = token
            return token.accessToken
        }
        let refreshed = try await refresh(token, clientID: clientID)
        try tokens.save(refreshed)
        cachedToken = refreshed
        return refreshed.accessToken
    }

    func disconnect() async throws {
        var token = cachedToken
        if token == nil { token = try tokens.load() }
        if let value = token?.refreshToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: "https://oauth2.googleapis.com/revoke?token=\(value)") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let (_, response) = try await send(request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw GoogleOAuthError.invalidResponse
            }
        }
        try tokens.delete()
        cachedToken = nil
    }

    private func exchangeCode(
        _ code: String,
        clientID: String,
        redirectURI: String,
        verifier: String
    ) async throws -> GoogleOAuthToken {
        try await tokenRequest(
            GoogleOAuthTokenForm.authorizationCode(
                code: code,
                clientID: clientID,
                clientSecret: clientSecret,
                redirectURI: redirectURI,
                verifier: verifier
            ),
            existingRefreshToken: nil,
            clientID: clientID
        )
    }

    private func refresh(_ token: GoogleOAuthToken, clientID: String) async throws -> GoogleOAuthToken {
        guard !clientSecret.isEmpty else { throw GoogleOAuthError.missingClientSecret }
        return try await tokenRequest(
            GoogleOAuthTokenForm.refresh(
                clientID: clientID,
                clientSecret: clientSecret,
                refreshToken: token.refreshToken
            ),
            existingRefreshToken: token.refreshToken,
            clientID: clientID
        )
    }

    private func tokenRequest(
        _ form: [URLQueryItem],
        existingRefreshToken: String?,
        clientID: String
    ) async throws -> GoogleOAuthToken {
        var components = URLComponents()
        components.queryItems = form
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            if let detail = try? JSONDecoder().decode(TokenErrorResponse.self, from: data) {
                throw GoogleOAuthError.authorizationDenied(detail.errorDescription ?? detail.error)
            }
            throw GoogleOAuthError.invalidResponse
        }
        let responseToken = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let refreshToken = responseToken.refreshToken ?? existingRefreshToken else {
            throw GoogleOAuthError.invalidResponse
        }
        return GoogleOAuthToken(
            accessToken: responseToken.accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(responseToken.expiresIn)),
            scope: responseToken.scope ?? Self.scope,
            clientID: clientID
        )
    }
}

enum GoogleOAuthTokenForm {
    static func authorizationCode(
        code: String,
        clientID: String,
        clientSecret: String,
        redirectURI: String,
        verifier: String
    ) -> [URLQueryItem] {
        [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
    }

    static func refresh(
        clientID: String,
        clientSecret: String,
        refreshToken: String
    ) -> [URLQueryItem] {
        [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ]
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
    }
}

private struct TokenErrorResponse: Decodable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

enum GoogleOAuthLoopbackEvent: Sendable {
    case ready(UInt16)
    case callback(URL)
}

enum GoogleOAuthLoopbackReceiver {
    static let callbackHTML = "<html><body><h2>Authorization returned to Studio Recorder.</h2><p>The app is finishing the connection. You can close this tab.</p></body></html>"

    static func events(timeout: Duration = .seconds(300)) throws -> AsyncThrowingStream<GoogleOAuthLoopbackEvent, Error> {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "StudioRecorder.GoogleOAuthLoopback")
        return AsyncThrowingStream { continuation in
            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: timeout)
                    continuation.finish(throwing: GoogleOAuthError.authorizationTimedOut)
                    listener.cancel()
                } catch {
                    return
                }
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else {
                        continuation.finish(throwing: GoogleOAuthError.invalidResponse)
                        return
                    }
                    continuation.yield(.ready(port))
                case .failed(let error):
                    continuation.finish(throwing: error)
                case .cancelled:
                    continuation.finish()
                default:
                    break
                }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, error in
                    guard error == nil,
                          let data,
                          let request = String(data: data, encoding: .utf8),
                          let path = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first,
                          let callback = URL(string: "http://127.0.0.1\(path)") else {
                        connection.cancel()
                        listener.cancel()
                        continuation.finish(throwing: GoogleOAuthError.invalidResponse)
                        return
                    }
                    let html = callbackHTML
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    continuation.yield(.callback(callback))
                    continuation.finish()
                    listener.cancel()
                }
            }
            continuation.onTermination = { _ in
                timeoutTask.cancel()
                listener.cancel()
            }
            listener.start(queue: queue)
        }
    }
}
