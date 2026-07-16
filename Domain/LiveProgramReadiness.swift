import Foundation

enum LiveProgramReadinessBlocker: Hashable, Sendable {
    case screen
    case camera
    case presentation
}

struct LiveProgramReadinessAttempt: Equatable, Identifiable, Sendable {
    let id: UUID
    let displayID: UInt32
    let presentation: CapturePresentationSnapshot
    let requiresCamera: Bool
    let screenStreamGeneration: UInt64
    let cameraOutputGeneration: UInt64?
    let startedAt: TimeInterval
}

enum LiveProgramReadinessError: LocalizedError, Equatable, Sendable {
    case screenUnavailable
    case cameraUnavailable
    case presentationUnavailable

    init(blockers: Set<LiveProgramReadinessBlocker>) {
        if blockers.contains(.screen) {
            self = .screenUnavailable
        } else if blockers.contains(.camera) {
            self = .cameraUnavailable
        } else {
            self = .presentationUnavailable
        }
    }

    var errorDescription: String? {
        switch self {
        case .screenUnavailable:
            "The selected screen did not produce a current frame. Streaming was not started."
        case .cameraUnavailable:
            "The visible camera did not produce a current frame. Streaming was not started."
        case .presentationUnavailable:
            "The prepared scene did not reach the live compositor. Streaming was not started."
        }
    }
}

final class LiveProgramReadinessTracker: @unchecked Sendable {
    private struct State {
        var attempt: LiveProgramReadinessAttempt?
        var screenPresentation: CapturePresentationSnapshot?
        var hasCameraEvidence = false
    }

    private let lock = NSLock()
    private var state = State()

    @discardableResult
    func begin(
        displayID: UInt32,
        presentation: CapturePresentationSnapshot,
        requiresCamera: Bool,
        screenStreamGeneration: UInt64,
        cameraOutputGeneration: UInt64?,
        at timestamp: TimeInterval
    ) -> LiveProgramReadinessAttempt {
        let attempt = LiveProgramReadinessAttempt(
            id: UUID(),
            displayID: displayID,
            presentation: presentation.validated(),
            requiresCamera: requiresCamera,
            screenStreamGeneration: screenStreamGeneration,
            cameraOutputGeneration: cameraOutputGeneration,
            startedAt: timestamp.isFinite ? timestamp : 0
        )
        lock.withLock {
            state = State(attempt: attempt)
        }
        return attempt
    }

    func cancel() {
        lock.withLock { state = State() }
    }

    func recordScreen(
        displayID: UInt32,
        streamGeneration: UInt64,
        presentation: CapturePresentationSnapshot,
        at timestamp: TimeInterval
    ) {
        guard timestamp.isFinite else { return }
        lock.withLock {
            guard let attempt = state.attempt,
                  timestamp >= attempt.startedAt,
                  displayID == attempt.displayID,
                  streamGeneration == attempt.screenStreamGeneration else { return }
            state.screenPresentation = presentation.validated()
        }
    }

    func recordCamera(outputGeneration: UInt64, at timestamp: TimeInterval) {
        guard timestamp.isFinite else { return }
        lock.withLock {
            guard let attempt = state.attempt,
                  timestamp >= attempt.startedAt,
                  attempt.requiresCamera,
                  attempt.cameraOutputGeneration == outputGeneration else { return }
            state.hasCameraEvidence = true
        }
    }

    func blockers(for attemptID: UUID) -> Set<LiveProgramReadinessBlocker>? {
        lock.withLock {
            guard let attempt = state.attempt,
                  attempt.id == attemptID else { return nil }
            var blockers: Set<LiveProgramReadinessBlocker> = []
            if let screenPresentation = state.screenPresentation {
                if screenPresentation != attempt.presentation {
                    blockers.insert(.presentation)
                }
            } else {
                blockers.insert(.screen)
            }
            if attempt.requiresCamera, !state.hasCameraEvidence {
                blockers.insert(.camera)
            }
            return blockers
        }
    }
}
