import Combine
import CoreGraphics
import Foundation
import Security

enum StreamDeliveryMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case record
    case stream
    case recordAndStream

    var id: String { rawValue }

    var label: String {
        switch self {
        case .record: "Record"
        case .stream: "Stream"
        case .recordAndStream: "Record + Stream"
        }
    }

    var includesRecording: Bool { self != .stream }
    var includesStreaming: Bool { self != .record }
}

struct YouTubeStreamConfiguration: Equatable, Sendable {
    let serverURL: URL
    let streamKey: String
    let canvasSize: CGSize
    let frameRate: Int
    let videoBitRate: Int
    let audioBitRate: Int

    init(
        serverURL: URL,
        streamKey: String,
        canvasSize: CGSize,
        frameRate: Int,
        videoBitRate: Int,
        audioBitRate: Int = 128_000
    ) {
        self.serverURL = serverURL
        self.streamKey = streamKey
        self.canvasSize = canvasSize
        self.frameRate = frameRate
        self.videoBitRate = videoBitRate
        self.audioBitRate = audioBitRate
    }

    var publishURL: URL? {
        guard serverURL.scheme?.lowercased() == "rtmps",
              serverURL.host != nil,
              !streamKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return serverURL.appending(path: streamKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

protocol StreamCredentialStoring: Sendable {
    func loadStreamKey() throws -> String?
    func saveStreamKey(_ key: String) throws
    func deleteStreamKey() throws
}

struct KeychainStreamCredentialStore: StreamCredentialStoring {
    private let service: String
    private let account: String

    init(
        service: String = "ua.com.rmarinsky.studiorecorder.youtube",
        account: String = "youtube-stream-key"
    ) {
        self.service = service
        self.account = account
    }

    func loadStreamKey() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StreamCredentialError.keychain(status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func saveStreamKey(_ key: String) throws {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            try deleteStreamKey()
            return
        }
        let data = Data(value.utf8)
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

    func deleteStreamKey() throws {
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

enum StreamCredentialError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
        }
    }
}

@MainActor
final class YouTubeStreamingSettingsStore: ObservableObject {
    static let defaultServerURL = "rtmps://a.rtmps.youtube.com/live2"
    static let serverURLKey = "youtubeStreaming.serverURL"
    static let videoBitRateKey = "youtubeStreaming.videoBitRate"
    static let audioBitRateKey = "youtubeStreaming.audioBitRate"
    static let legacyOAuthClientIDKey = "youtubeStreaming.oauthClientID"
    static let usesManagedYouTubeKey = "youtubeStreaming.usesManagedYouTube"
    static let bundledOAuthClientIDKey = "GoogleOAuthClientID"
    static let bundledOAuthClientSecretKey = "GoogleOAuthClientSecret"

    @Published var serverURL: String
    @Published var streamKey: String
    @Published var videoBitRate: Int
    @Published var audioBitRate: Int
    @Published var usesManagedYouTube: Bool
    @Published private(set) var credentialError: String?
    let oauthClientID: String
    let hasOAuthClientSecret: Bool

    private let defaults: UserDefaults
    private let credentials: any StreamCredentialStoring

    init(
        defaults: UserDefaults = .standard,
        credentials: any StreamCredentialStoring = KeychainStreamCredentialStore(),
        bundle: Bundle = .main,
        bundledOAuthClientID: String? = nil,
        bundledOAuthClientSecret: String? = nil
    ) {
        self.defaults = defaults
        self.credentials = credentials
        serverURL = defaults.string(forKey: Self.serverURLKey) ?? Self.defaultServerURL
        let savedBitRate = defaults.integer(forKey: Self.videoBitRateKey)
        videoBitRate = savedBitRate > 0 ? savedBitRate : 10_000_000
        let savedAudioBitRate = defaults.integer(forKey: Self.audioBitRateKey)
        audioBitRate = savedAudioBitRate > 0 ? savedAudioBitRate : 128_000
        oauthClientID = (bundledOAuthClientID
            ?? (bundle.object(forInfoDictionaryKey: Self.bundledOAuthClientIDKey) as? String)
            ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let oauthClientSecret = (bundledOAuthClientSecret
            ?? (bundle.object(forInfoDictionaryKey: Self.bundledOAuthClientSecretKey) as? String)
            ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        hasOAuthClientSecret = !oauthClientSecret.isEmpty
        usesManagedYouTube = defaults.object(forKey: Self.usesManagedYouTubeKey) as? Bool ?? true
        defaults.removeObject(forKey: Self.legacyOAuthClientIDKey)
        do {
            streamKey = try credentials.loadStreamKey() ?? ""
        } catch {
            streamKey = ""
            credentialError = error.localizedDescription
        }
    }

    var isReady: Bool {
        configuration(canvasSize: CGSize(width: 1_920, height: 1_080), frameRate: 30) != nil
    }

    var isManagedYouTubeConfigured: Bool {
        !oauthClientID.isEmpty && hasOAuthClientSecret
    }

    func configuration(canvasSize: CGSize, frameRate: Int) -> YouTubeStreamConfiguration? {
        guard let server = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        let configuration = YouTubeStreamConfiguration(
            serverURL: server,
            streamKey: streamKey,
            canvasSize: canvasSize,
            frameRate: frameRate,
            videoBitRate: min(max(videoBitRate, 3_000_000), 40_000_000),
            audioBitRate: min(max(audioBitRate, 128_000), 256_000)
        )
        return configuration.publishURL == nil ? nil : configuration
    }

    func save() {
        serverURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        videoBitRate = min(max(videoBitRate, 3_000_000), 40_000_000)
        audioBitRate = min(max(audioBitRate, 128_000), 256_000)
        defaults.set(serverURL, forKey: Self.serverURLKey)
        defaults.set(videoBitRate, forKey: Self.videoBitRateKey)
        defaults.set(audioBitRate, forKey: Self.audioBitRateKey)
        defaults.set(usesManagedYouTube, forKey: Self.usesManagedYouTubeKey)
        do {
            try credentials.saveStreamKey(streamKey)
            credentialError = nil
        } catch {
            credentialError = error.localizedDescription
        }
    }
}
