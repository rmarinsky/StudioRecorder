import AppKit
import Combine
import CoreGraphics
import Foundation

enum YouTubeManagedSessionState: Equatable, Sendable {
    case idle
    case recovered(String)
    case authorizing
    case preparing
    case waitingForIngestion
    case testing
    case live
    case completing
    case failed(String)

    var label: String {
        switch self {
        case .idle: "Ready"
        case .recovered(let title): "Resume or end \(title)"
        case .authorizing: "Connecting Google account"
        case .preparing: "Preparing YouTube event"
        case .waitingForIngestion: "Waiting for YouTube ingestion"
        case .testing: "Starting YouTube preview"
        case .live: "YouTube broadcast is live"
        case .completing: "Completing YouTube broadcast"
        case .failed(let message): message
        }
    }
}

@MainActor
final class YouTubeManagedSessionCoordinator: ObservableObject {
    @Published private(set) var isAuthorized = false
    @Published private(set) var state: YouTubeManagedSessionState = .idle
    @Published private(set) var pendingSession: YouTubeManagedSessionJournalEntry?
    @Published private(set) var serverHealth: YouTubeRemoteHealth?
    @Published private(set) var configuration: YouTubeStreamConfiguration?
    @Published private(set) var upcomingBroadcasts: [YouTubeScheduledBroadcast] = []
    @Published var selectedBroadcastID: String?
    @Published private(set) var isLoadingBroadcasts = false
    @Published private(set) var broadcastListError: String?

    private let oauth: GoogleYouTubeOAuthClient
    private let journal: YouTubeManagedSessionJournal
    private let apiSend: YouTubeLiveAPIClient.Send
    private let connectOAuth: @Sendable (String) async throws -> Void
    private let activateApp: @MainActor @Sendable () -> Void
    private var monitorTask: Task<Void, Never>?
    private var usesBackupOnNextReconnect = true

    init(
        oauth: GoogleYouTubeOAuthClient = GoogleYouTubeOAuthClient(),
        journal: YouTubeManagedSessionJournal = YouTubeManagedSessionJournal(),
        apiSend: @escaping YouTubeLiveAPIClient.Send = { try await URLSession.shared.data(for: $0) },
        connectOAuth: (@Sendable (String) async throws -> Void)? = nil,
        activateApp: @escaping @MainActor @Sendable () -> Void = {
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    ) {
        self.oauth = oauth
        self.journal = journal
        self.apiSend = apiSend
        self.connectOAuth = connectOAuth ?? { clientID in
            try await oauth.connect(clientID: clientID)
        }
        self.activateApp = activateApp
        Task { [weak self] in await self?.restore() }
    }

    func restore() async {
        isAuthorized = await oauth.hasStoredAuthorization()
        do {
            pendingSession = try await journal.load()
            if let pendingSession {
                state = .recovered(pendingSession.title)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func connect(clientID: String) async {
        state = .authorizing
        do {
            try await connectOAuth(clientID)
        } catch {
            activateApp()
            state = .failed(Self.authorizationFailureMessage(for: error))
            return
        }
        activateApp()
        isAuthorized = true
        await reconcile(clientID: clientID)
        if pendingSession == nil {
            await refreshUpcomingBroadcasts(clientID: clientID)
        }
    }

    private static func authorizationFailureMessage(for error: Error) -> String {
        switch error as? GoogleOAuthError {
        case .authorizationDenied(let reason) where reason == "access_denied":
            "Google authorization was cancelled. Try again."
        case .authorizationTimedOut:
            "Google authorization timed out. Try again."
        case .missingClientID, .missingClientSecret:
            "YouTube connection is unavailable in this build."
        default:
            "Couldn’t connect YouTube. Try again."
        }
    }

    func reconcile(clientID: String) async {
        isAuthorized = await oauth.hasStoredAuthorization()
        var restored = pendingSession
        if restored == nil { restored = try? await journal.load() }
        guard let entry = restored else {
            state = .idle
            return
        }
        pendingSession = entry
        guard isAuthorized, !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .recovered(entry.title)
            return
        }
        do {
            let api = makeAPI(clientID: clientID)
            let broadcast = try await api.broadcast(id: entry.broadcastID)
            switch broadcast.status?.lifeCycleStatus ?? .unknown {
            case .complete, .revoked:
                try await clearRecoveredSession()
                return
            case .created, .ready, .testStarting, .testing, .liveStarting, .live:
                break
            case .unknown:
                throw YouTubeAPIError.requestFailed(
                    status: 409,
                    detail: "The recovered YouTube event has an unknown lifecycle state."
                )
            }
            if let streamID = entry.streamID {
                let stream = try await api.stream(id: streamID)
                serverHealth = stream.health
            }
            state = .recovered(entry.title)
            if entry.cleanStopRequested {
                await complete(clientID: clientID)
            }
        } catch YouTubeAPIError.resourceNotFound {
            do {
                try await clearRecoveredSession()
            } catch {
                state = .failed(error.localizedDescription)
            }
        } catch {
            state = .failed("The recovered YouTube event needs attention. \(error.localizedDescription)")
        }
    }

    func associateLocalProject(_ projectID: UUID) async {
        guard var entry = pendingSession, entry.localProjectID != projectID else { return }
        entry.localProjectID = projectID
        do {
            try await journal.save(entry)
            pendingSession = entry
        } catch {
            state = .failed("Could not update YouTube recovery metadata. \(error.localizedDescription)")
        }
    }

    func refreshUpcomingBroadcasts(clientID: String) async {
        guard isAuthorized else {
            upcomingBroadcasts = []
            selectedBroadcastID = nil
            return
        }
        isLoadingBroadcasts = true
        broadcastListError = nil
        defer { isLoadingBroadcasts = false }
        do {
            upcomingBroadcasts = try await makeAPI(clientID: clientID).upcomingBroadcasts()
            if let selectedBroadcastID,
               !upcomingBroadcasts.contains(where: { $0.id == selectedBroadcastID }) {
                self.selectedBroadcastID = nil
            }
        } catch {
            broadcastListError = error.localizedDescription
        }
    }

    func disconnect() async {
        monitorTask?.cancel()
        monitorTask = nil
        do {
            try await oauth.disconnect()
            isAuthorized = false
            configuration = nil
            serverHealth = nil
            upcomingBroadcasts = []
            selectedBroadcastID = nil
            broadcastListError = nil
            state = pendingSession.map { .recovered($0.title) } ?? .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func prepareConfiguration(
        clientID: String,
        canvasSize: CGSize,
        frameRate: Int,
        videoBitRate: Int,
        audioBitRate: Int,
        localProjectID: UUID? = nil,
        deliveryMode: StreamDeliveryMode? = nil
    ) async throws -> YouTubeStreamConfiguration {
        state = .preparing
        usesBackupOnNextReconnect = true
        let api = makeAPI(clientID: clientID)
        let entry: YouTubeManagedSessionJournalEntry
        let remoteStream: YouTubeRemoteStream

        var restored = pendingSession
        if restored == nil { restored = try await journal.load() }
        if var existing = restored {
            let broadcast = try await api.broadcast(id: existing.broadcastID)
            if broadcast.status?.lifeCycleStatus == .complete {
                try await journal.clear()
                pendingSession = nil
                return try await createConfiguration(
                    api: api,
                    canvasSize: canvasSize,
                    frameRate: frameRate,
                    videoBitRate: videoBitRate,
                    audioBitRate: audioBitRate,
                    localProjectID: localProjectID,
                    deliveryMode: deliveryMode
                )
            }
            if broadcast.status?.lifeCycleStatus == .revoked {
                throw YouTubeAPIError.requestFailed(
                    status: 409,
                    detail: "The recovered YouTube event was revoked and cannot be resumed."
                )
            }
            if let streamID = existing.streamID {
                remoteStream = try await api.stream(id: streamID)
                if broadcast.contentDetails?.boundStreamId != streamID {
                    _ = try await api.bind(broadcastID: existing.broadcastID, streamID: streamID)
                }
            } else {
                remoteStream = try await api.createStream(title: existing.title)
                existing.streamID = remoteStream.id
                try await journal.save(existing)
                _ = try await api.bind(broadcastID: existing.broadcastID, streamID: remoteStream.id)
            }
            entry = existing
        } else {
            if let selectedBroadcastID {
                return try await prepareScheduledConfiguration(
                    api: api,
                    broadcastID: selectedBroadcastID,
                    canvasSize: canvasSize,
                    frameRate: frameRate,
                    videoBitRate: videoBitRate,
                    audioBitRate: audioBitRate,
                    localProjectID: localProjectID,
                    deliveryMode: deliveryMode
                )
            }
            return try await createConfiguration(
                api: api,
                canvasSize: canvasSize,
                frameRate: frameRate,
                videoBitRate: videoBitRate,
                audioBitRate: audioBitRate,
                localProjectID: localProjectID,
                deliveryMode: deliveryMode
            )
        }

        guard let ingestion = remoteStream.ingestion else { throw YouTubeAPIError.missingIngestion }
        pendingSession = entry
        serverHealth = remoteStream.health
        let configuration = makeConfiguration(
            ingestion: ingestion,
            canvasSize: canvasSize,
            frameRate: frameRate,
            videoBitRate: videoBitRate,
            audioBitRate: audioBitRate
        )
        self.configuration = configuration
        state = .waitingForIngestion
        return configuration
    }

    func refreshedConfiguration(
        clientID: String,
        previous: YouTubeStreamConfiguration
    ) async throws -> YouTubeStreamConfiguration {
        guard let entry = pendingSession, let streamID = entry.streamID else { return previous }
        let api = makeAPI(clientID: clientID)
        let broadcast = try await api.broadcast(id: entry.broadcastID)
        switch broadcast.status?.lifeCycleStatus ?? .unknown {
        case .complete:
            try await clearRecoveredSession()
            throw YouTubeAPIError.requestFailed(status: 409, detail: "The YouTube event has completed.")
        case .revoked:
            let error = YouTubeAPIError.requestFailed(status: 409, detail: "The YouTube event was revoked.")
            state = .failed(error.localizedDescription)
            throw error
        case .created, .ready, .testStarting, .testing, .liveStarting, .live:
            break
        case .unknown:
            let error = YouTubeAPIError.requestFailed(status: 409, detail: "YouTube returned an unknown broadcast state.")
            state = .failed(error.localizedDescription)
            throw error
        }
        let remote = try await api.stream(id: streamID)
        serverHealth = remote.health
        guard let ingestion = remote.ingestion else { throw YouTubeAPIError.missingIngestion }
        let serverURL: URL
        if usesBackupOnNextReconnect, let backup = ingestion.backupServerURL {
            serverURL = backup
        } else {
            serverURL = ingestion.serverURL
        }
        usesBackupOnNextReconnect.toggle()
        let refreshed = makeConfiguration(
            serverURL: serverURL,
            streamKey: ingestion.streamKey,
            canvasSize: previous.canvasSize,
            frameRate: previous.frameRate,
            videoBitRate: previous.videoBitRate,
            audioBitRate: previous.audioBitRate
        )
        configuration = refreshed
        return refreshed
    }

    func beginActivation(clientID: String) {
        guard monitorTask == nil, pendingSession?.streamID != nil else { return }
        monitorTask = Task { [weak self] in
            await self?.activateAndMonitor(clientID: clientID)
        }
    }

    func pauseMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        if let pendingSession {
            state = .recovered(pendingSession.title)
        }
    }

    func reportFailure(_ message: String) {
        state = .failed(message)
    }

    func complete(clientID: String) async {
        monitorTask?.cancel()
        monitorTask = nil
        var restored = pendingSession
        if restored == nil { restored = try? await journal.load() }
        guard let entry = restored else {
            state = .idle
            return
        }
        state = .completing
        do {
            var stoppingEntry = entry
            stoppingEntry.cleanStopRequested = true
            try await journal.save(stoppingEntry)
            pendingSession = stoppingEntry
            let api = makeAPI(clientID: clientID)
            var confirmed = false
            var didRequestCompletion = false
            for _ in 0..<20 {
                let current = try await api.broadcast(id: entry.broadcastID)
                switch current.status?.lifeCycleStatus ?? .unknown {
                case .complete, .revoked:
                    confirmed = true
                case .created, .ready:
                    if entry.ownsBroadcast {
                        try await api.deleteBroadcast(id: entry.broadcastID)
                    }
                    confirmed = true
                case .testing, .live:
                    if !didRequestCompletion {
                        _ = try await api.transition(broadcastID: entry.broadcastID, to: .complete)
                        didRequestCompletion = true
                    }
                case .testStarting, .liveStarting:
                    break
                case .unknown:
                    throw YouTubeAPIError.requestFailed(
                        status: 409,
                        detail: "YouTube returned an unknown broadcast state while stopping."
                    )
                }
                if confirmed { break }
                try await Task.sleep(for: .seconds(1))
            }
            guard confirmed else {
                throw YouTubeAPIError.requestFailed(
                    status: 408,
                    detail: "YouTube did not confirm that the broadcast completed."
                )
            }
            try await clearRecoveredSession()
            await refreshUpcomingBroadcasts(clientID: clientID)
        } catch {
            state = .failed("YouTube event still needs attention. \(error.localizedDescription)")
        }
    }

    private func createConfiguration(
        api: YouTubeLiveAPIClient,
        canvasSize: CGSize,
        frameRate: Int,
        videoBitRate: Int,
        audioBitRate: Int,
        localProjectID: UUID?,
        deliveryMode: StreamDeliveryMode?
    ) async throws -> YouTubeStreamConfiguration {
        let title = "Studio Recorder Live \(Date().formatted(date: .abbreviated, time: .shortened))"
        let broadcast = try await api.createBroadcast(
            title: title,
            scheduledStartTime: Date().addingTimeInterval(60)
        )
        var entry = YouTubeManagedSessionJournalEntry(
            broadcastID: broadcast.id,
            streamID: nil,
            title: title,
            createdAt: Date(),
            localProjectID: localProjectID,
            deliveryMode: deliveryMode
        )
        try await journal.save(entry)
        pendingSession = entry

        let stream = try await api.createStream(title: title)
        entry.streamID = stream.id
        try await journal.save(entry)
        pendingSession = entry
        _ = try await api.bind(broadcastID: broadcast.id, streamID: stream.id)
        guard let ingestion = stream.ingestion else { throw YouTubeAPIError.missingIngestion }
        serverHealth = stream.health
        let configuration = makeConfiguration(
            ingestion: ingestion,
            canvasSize: canvasSize,
            frameRate: frameRate,
            videoBitRate: videoBitRate,
            audioBitRate: audioBitRate
        )
        self.configuration = configuration
        state = .waitingForIngestion
        return configuration
    }

    private func prepareScheduledConfiguration(
        api: YouTubeLiveAPIClient,
        broadcastID: String,
        canvasSize: CGSize,
        frameRate: Int,
        videoBitRate: Int,
        audioBitRate: Int,
        localProjectID: UUID?,
        deliveryMode: StreamDeliveryMode?
    ) async throws -> YouTubeStreamConfiguration {
        let broadcast = try await api.broadcast(id: broadcastID)
        guard [.created, .ready].contains(broadcast.status?.lifeCycleStatus ?? .unknown) else {
            throw YouTubeAPIError.requestFailed(
                status: 409,
                detail: "The selected YouTube broadcast is no longer upcoming. Refresh and choose another broadcast."
            )
        }
        let selected = upcomingBroadcasts.first(where: { $0.id == broadcastID })
        let title = broadcast.snippet?.title ?? selected?.title ?? "YouTube Live"
        var entry = YouTubeManagedSessionJournalEntry(
            broadcastID: broadcastID,
            streamID: broadcast.contentDetails?.boundStreamId,
            title: title,
            createdAt: Date(),
            localProjectID: localProjectID,
            deliveryMode: deliveryMode,
            ownsBroadcast: false
        )
        try await journal.save(entry)
        pendingSession = entry

        let stream: YouTubeRemoteStream
        if let streamID = entry.streamID {
            stream = try await api.stream(id: streamID)
        } else {
            stream = try await api.createStream(title: title)
            entry.streamID = stream.id
            try await journal.save(entry)
            pendingSession = entry
            _ = try await api.bind(broadcastID: broadcastID, streamID: stream.id)
        }
        guard let ingestion = stream.ingestion else { throw YouTubeAPIError.missingIngestion }
        serverHealth = stream.health
        let configuration = makeConfiguration(
            ingestion: ingestion,
            canvasSize: canvasSize,
            frameRate: frameRate,
            videoBitRate: videoBitRate,
            audioBitRate: audioBitRate
        )
        self.configuration = configuration
        state = .waitingForIngestion
        return configuration
    }

    private func activateAndMonitor(clientID: String) async {
        guard let entry = pendingSession, let streamID = entry.streamID else { return }
        let api = makeAPI(clientID: clientID)
        var consecutivePollFailures = 0
        do {
            var startupPolls = 0
            while !Task.isCancelled {
                try Task.checkCancellation()
                let stream: YouTubeRemoteStream
                let broadcast: YouTubeLiveAPIClient.BroadcastResource
                do {
                    stream = try await api.stream(id: streamID)
                    broadcast = try await api.broadcast(id: entry.broadcastID)
                    consecutivePollFailures = 0
                } catch {
                    consecutivePollFailures += 1
                    if isTerminal(error) || consecutivePollFailures >= 5 { throw error }
                    try await Task.sleep(for: .seconds(min(1 << consecutivePollFailures, 30)))
                    continue
                }
                serverHealth = stream.health
                let action = YouTubeManagedLifecycle.nextAction(
                    broadcastStatus: broadcast.status?.lifeCycleStatus ?? .unknown,
                    streamStatus: stream.status
                )
                switch action {
                case .waitForIngestion:
                    state = .waitingForIngestion
                case .transitionToTesting:
                    state = .testing
                    do {
                        _ = try await api.transition(broadcastID: entry.broadcastID, to: .testing)
                    } catch {
                        if isTerminal(error) { throw error }
                        try await Task.sleep(for: .seconds(2))
                        continue
                    }
                case .waitForTesting:
                    state = .testing
                case .transitionToLive:
                    do {
                        _ = try await api.transition(broadcastID: entry.broadcastID, to: .live)
                    } catch {
                        if isTerminal(error) { throw error }
                        try await Task.sleep(for: .seconds(2))
                        continue
                    }
                case .waitForLive:
                    state = .testing
                case .monitor:
                    state = .live
                case .finished:
                    try await journal.clear()
                    pendingSession = nil
                    configuration = nil
                    serverHealth = nil
                    state = .idle
                    monitorTask = nil
                    return
                case .failed:
                    throw YouTubeAPIError.requestFailed(
                        status: 409,
                        detail: "The broadcast or ingestion stream entered an unrecoverable state."
                    )
                }
                if action != .monitor {
                    startupPolls += 1
                    if startupPolls >= 90 {
                        throw YouTubeAPIError.requestFailed(
                            status: 408,
                            detail: "YouTube did not reach the live state before the timeout."
                        )
                    }
                }
                try await Task.sleep(for: .seconds(action == .monitor ? 5 : 2))
            }
        } catch is CancellationError {
            return
        } catch {
            state = .failed(error.localizedDescription)
            monitorTask = nil
        }
    }

    private func clearRecoveredSession() async throws {
        try await journal.clear()
        pendingSession = nil
        configuration = nil
        serverHealth = nil
        state = .idle
    }

    private func isTerminal(_ error: Error) -> Bool {
        if error is GoogleOAuthError { return true }
        guard let apiError = error as? YouTubeAPIError else { return false }
        switch apiError {
        case .resourceNotFound, .missingIngestion:
            return true
        case .requestFailed(let status, _):
            return (400..<500).contains(status) && status != 408 && status != 429
        case .invalidResponse:
            return false
        }
    }

    private func makeAPI(clientID: String) -> YouTubeLiveAPIClient {
        let oauth = self.oauth
        return YouTubeLiveAPIClient(accessToken: {
            try await oauth.validAccessToken(clientID: clientID)
        }, send: apiSend)
    }

    private func makeConfiguration(
        ingestion: YouTubeIngestion,
        canvasSize: CGSize,
        frameRate: Int,
        videoBitRate: Int,
        audioBitRate: Int
    ) -> YouTubeStreamConfiguration {
        makeConfiguration(
            serverURL: ingestion.serverURL,
            streamKey: ingestion.streamKey,
            canvasSize: canvasSize,
            frameRate: frameRate,
            videoBitRate: videoBitRate,
            audioBitRate: audioBitRate
        )
    }

    private func makeConfiguration(
        serverURL: URL,
        streamKey: String,
        canvasSize: CGSize,
        frameRate: Int,
        videoBitRate: Int,
        audioBitRate: Int
    ) -> YouTubeStreamConfiguration {
        YouTubeStreamConfiguration(
            serverURL: serverURL,
            streamKey: streamKey,
            canvasSize: canvasSize,
            frameRate: frameRate,
            videoBitRate: min(max(videoBitRate, 3_000_000), 40_000_000),
            audioBitRate: min(max(audioBitRate, 128_000), 256_000)
        )
    }
}
