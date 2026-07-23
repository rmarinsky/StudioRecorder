import Foundation

enum LiveSourceRecoveryDecision: Equatable, Sendable {
    case restartScreen(source: LiveSourceID, attempt: Int, maximumAttempts: Int)
    case restartCamera(source: LiveSourceID, attempt: Int, maximumAttempts: Int)
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

enum LiveCameraRecoveryPolicy {
    static func shouldRebuildSession(hasActiveMovieOutput: Bool) -> Bool {
        !hasActiveMovieOutput
    }
}

struct LiveSourceRecoveryPolicy: Sendable {
    let maximumAttempts: Int
    let cooldown: TimeInterval

    private var source: LiveSourceID?
    private var attempts = 0
    private var isAttemptInFlight = false
    private var lastCompletedAt: TimeInterval?
    private var exhaustedSources: [LiveSourceID: TimeInterval] = [:]

    init(maximumAttempts: Int = 2, cooldown: TimeInterval = 2) {
        self.maximumAttempts = max(maximumAttempts, 1)
        self.cooldown = max(cooldown.isFinite ? cooldown : 2, 0)
    }

    func exhaustedSource(at timestamp: TimeInterval) -> LiveSourceID? {
        let timestamp = timestamp.isFinite ? timestamp : 0
        if !isAttemptInFlight,
           attempts >= maximumAttempts,
           let lastCompletedAt,
           timestamp - lastCompletedAt >= cooldown {
            return source
        }
        return exhaustedSources
            .filter({ $0.value <= timestamp })
            .map(\.key)
            .sorted(by: { $0.id < $1.id })
            .first
    }

    mutating func decision(
        for snapshot: LiveSourceHealthSnapshot,
        at timestamp: TimeInterval
    ) -> LiveSourceRecoveryDecision? {
        let timestamp = timestamp.isFinite ? timestamp : 0
        for recovered in snapshot.entries where recovered.state == .recovered {
            exhaustedSources.removeValue(forKey: recovered.source)
            if source == recovered.source { resetCurrentSource() }
        }
        if let exhausted = exhaustedSource(at: timestamp),
           snapshot[exhausted]?.state == .stalled {
            exhaustedSources[exhausted] = lastCompletedAt.map { $0 + cooldown } ?? timestamp
            if source == exhausted { resetCurrentSource() }
        }
        guard let stalledSource = snapshot.entries.first(where: {
            $0.state == .stalled && !isRecoveryTargetExhausted(for: $0.source)
        })?.source else { return nil }
        if let source,
           source != stalledSource,
           !sharesRecoveryTarget(source, stalledSource) {
            guard !isAttemptInFlight else { return nil }
            resetCurrentSource()
        }
        guard !isAttemptInFlight,
              attempts < maximumAttempts else { return nil }
        if let lastCompletedAt,
           timestamp - lastCompletedAt < cooldown { return nil }
        source = stalledSource
        attempts += 1
        isAttemptInFlight = true
        switch stalledSource.category {
        case .camera:
            return .restartCamera(
                source: stalledSource,
                attempt: attempts,
                maximumAttempts: maximumAttempts
            )
        case .screen, .systemAudio, .microphone:
            return .restartScreen(
                source: stalledSource,
                attempt: attempts,
                maximumAttempts: maximumAttempts
            )
        }
    }

    mutating func complete(source: LiveSourceID, at timestamp: TimeInterval) {
        guard self.source == source,
              isAttemptInFlight else { return }
        isAttemptInFlight = false
        lastCompletedAt = timestamp.isFinite ? timestamp : 0
    }

    mutating func reset() {
        exhaustedSources.removeAll()
        resetCurrentSource()
    }

    private mutating func resetCurrentSource() {
        source = nil
        attempts = 0
        isAttemptInFlight = false
        lastCompletedAt = nil
    }

    private func isRecoveryTargetExhausted(for candidate: LiveSourceID) -> Bool {
        exhaustedSources.keys.contains { sharesRecoveryTarget($0, candidate) }
    }

    private func sharesRecoveryTarget(_ lhs: LiveSourceID, _ rhs: LiveSourceID) -> Bool {
        if lhs.category == .camera || rhs.category == .camera {
            return lhs.category == rhs.category
        }
        return true
    }
}
