import Foundation

enum LiveSourceRecoveryDecision: Equatable, Sendable {
    case restartScreen(source: LiveSourceID, attempt: Int, maximumAttempts: Int)
}

enum LiveSourceRecoveryState: Equatable, Sendable {
    case idle
    case restarting(source: LiveSourceID, attempt: Int, maximumAttempts: Int)
    case waitingForSamples(source: LiveSourceID, attempt: Int, maximumAttempts: Int)
    case failed(source: LiveSourceID, message: String)
}

struct LiveScreenIngressRestartError: LocalizedError, Equatable, Sendable {
    let detail: String

    var errorDescription: String? { detail }
}

struct LiveScreenIngressRestartExecutor {
    @MainActor
    func restart(
        resumeExisting: () async throws -> Void,
        rebuild: () async throws -> Void
    ) async throws {
        do {
            try await resumeExisting()
        } catch let resumeError {
            do {
                try await rebuild()
            } catch let rebuildError {
                throw LiveScreenIngressRestartError(
                    detail: "The live screen source could not restart. Resume failed: \(resumeError.localizedDescription) Rebuild failed: \(rebuildError.localizedDescription)"
                )
            }
        }
    }
}

struct LiveSourceRecoveryPolicy: Sendable {
    let maximumAttempts: Int
    let cooldown: TimeInterval

    private var source: LiveSourceID?
    private var attempts = 0
    private var isAttemptInFlight = false
    private var lastCompletedAt: TimeInterval?

    init(maximumAttempts: Int = 2, cooldown: TimeInterval = 2) {
        self.maximumAttempts = max(maximumAttempts, 1)
        self.cooldown = max(cooldown.isFinite ? cooldown : 2, 0)
    }

    func exhaustedSource(at timestamp: TimeInterval) -> LiveSourceID? {
        guard !isAttemptInFlight,
              attempts >= maximumAttempts,
              let lastCompletedAt else { return nil }
        let timestamp = timestamp.isFinite ? timestamp : 0
        guard timestamp - lastCompletedAt >= cooldown else { return nil }
        return source
    }

    mutating func decision(
        for snapshot: LiveSourceHealthSnapshot,
        at timestamp: TimeInterval
    ) -> LiveSourceRecoveryDecision? {
        let timestamp = timestamp.isFinite ? timestamp : 0
        if snapshot.entries.contains(where: {
            $0.source.category == .screen && $0.state == .recovered
        }) {
            reset()
            return nil
        }
        guard let stalledScreen = snapshot.entries.first(where: {
            $0.source.category == .screen && $0.state == .stalled
        })?.source else { return nil }
        if source != nil, source != stalledScreen {
            guard !isAttemptInFlight else { return nil }
            reset()
        }
        guard !isAttemptInFlight,
              attempts < maximumAttempts else { return nil }
        if let lastCompletedAt,
           timestamp - lastCompletedAt < cooldown { return nil }
        source = stalledScreen
        attempts += 1
        isAttemptInFlight = true
        return .restartScreen(
            source: stalledScreen,
            attempt: attempts,
            maximumAttempts: maximumAttempts
        )
    }

    mutating func complete(source: LiveSourceID, at timestamp: TimeInterval) {
        guard self.source == source,
              isAttemptInFlight else { return }
        isAttemptInFlight = false
        lastCompletedAt = timestamp.isFinite ? timestamp : 0
    }

    mutating func reset() {
        source = nil
        attempts = 0
        isAttemptInFlight = false
        lastCompletedAt = nil
    }
}
