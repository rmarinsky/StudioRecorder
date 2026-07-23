import Foundation

enum LiveSourceCategory: String, Hashable, Sendable {
    case screen
    case camera
    case systemAudio
    case microphone
}

struct LiveSourceID: Hashable, Identifiable, Sendable {
    let category: LiveSourceCategory
    let discriminator: String?

    static func screen(displayID: UInt32) -> Self {
        Self(category: .screen, discriminator: String(displayID))
    }

    static let camera = Self(category: .camera, discriminator: nil)
    static let systemAudio = Self(category: .systemAudio, discriminator: nil)
    static let microphone = Self(category: .microphone, discriminator: nil)

    var id: String { [category.rawValue, discriminator].compactMap { $0 }.joined(separator: "-") }

    var label: String {
        switch category {
        case .screen: discriminator.map { "Display \($0)" } ?? "Screen"
        case .camera: "Camera"
        case .systemAudio: "System Audio"
        case .microphone: "Microphone"
        }
    }

    var systemImage: String {
        switch category {
        case .screen: "display"
        case .camera: "video.fill"
        case .systemAudio: "speaker.wave.2.fill"
        case .microphone: "mic.fill"
        }
    }

    fileprivate var isAudio: Bool {
        category == .systemAudio || category == .microphone
    }
}

enum LiveSourceHealthState: Equatable, Sendable {
    case waiting
    case active
    case stalled
    case recovered
}

struct LiveSourceHealthEntry: Equatable, Identifiable, Sendable {
    let source: LiveSourceID
    let state: LiveSourceHealthState
    let secondsSinceLastSample: TimeInterval?

    var id: LiveSourceID { source }
}

struct LiveSourceHealthSnapshot: Equatable, Sendable {
    let entries: [LiveSourceHealthEntry]

    static let empty = Self(entries: [])

    var hasStalledSources: Bool { entries.contains { $0.state == .stalled } }
    var stalledSources: [LiveSourceID] {
        entries.filter { $0.state == .stalled }.map(\.source)
    }

    subscript(source: LiveSourceID) -> LiveSourceHealthEntry? {
        entries.first { $0.source == source }
    }
}

final class LiveSourceHealthMonitor: @unchecked Sendable {
    private struct State {
        var expected: Set<LiveSourceID> = []
        var configuredAt: TimeInterval = 0
        var lastSampleAt: [LiveSourceID: TimeInterval] = [:]
        var invalidatedSources: Set<LiveSourceID> = []
        var stalledSources: Set<LiveSourceID> = []
        var recoveredAt: [LiveSourceID: TimeInterval] = [:]
    }

    private let lock = NSLock()
    private let startupGrace: TimeInterval
    private let videoStallThreshold: TimeInterval
    private let audioStallThreshold: TimeInterval
    private let recoveryDisplayDuration: TimeInterval
    private var state = State()

    init(
        startupGrace: TimeInterval = 3,
        videoStallThreshold: TimeInterval = 1.5,
        audioStallThreshold: TimeInterval = 2,
        recoveryDisplayDuration: TimeInterval = 3
    ) {
        self.startupGrace = max(startupGrace.isFinite ? startupGrace : 3, 0)
        self.videoStallThreshold = max(videoStallThreshold.isFinite ? videoStallThreshold : 1.5, 0.1)
        self.audioStallThreshold = max(audioStallThreshold.isFinite ? audioStallThreshold : 2, 0.1)
        self.recoveryDisplayDuration = max(
            recoveryDisplayDuration.isFinite ? recoveryDisplayDuration : 3,
            0
        )
    }

    func configure(expected: Set<LiveSourceID>, at timestamp: TimeInterval) {
        let timestamp = timestamp.isFinite ? timestamp : 0
        lock.withLock {
            state = State(expected: expected, configuredAt: timestamp)
        }
    }

    func record(_ source: LiveSourceID, at timestamp: TimeInterval) {
        recordSample(source, at: timestamp)
    }

    func recordIdle(_ source: LiveSourceID, at timestamp: TimeInterval) {
        recordSample(source, at: timestamp)
    }

    func invalidate(_ source: LiveSourceID) {
        lock.withLock {
            guard state.expected.contains(source) else { return }
            state.invalidatedSources.insert(source)
        }
    }

    private func recordSample(_ source: LiveSourceID, at timestamp: TimeInterval) {
        guard timestamp.isFinite else { return }
        lock.withLock {
            guard state.expected.contains(source) else { return }
            let timestamp = max(timestamp, state.configuredAt)
            state.lastSampleAt[source] = timestamp
            state.invalidatedSources.remove(source)
            if state.stalledSources.remove(source) != nil {
                state.recoveredAt[source] = timestamp
            }
        }
    }

    func snapshot(at timestamp: TimeInterval) -> LiveSourceHealthSnapshot {
        let timestamp = timestamp.isFinite ? timestamp : 0
        return lock.withLock {
            LiveSourceHealthSnapshot(entries: state.expected.sorted { $0.id < $1.id }.map { source in
                if let lastSample = state.lastSampleAt[source] {
                    let silence = max(timestamp - lastSample, 0)
                    let threshold = source.isAudio ? audioStallThreshold : videoStallThreshold
                    if state.invalidatedSources.contains(source) || silence > threshold {
                        state.stalledSources.insert(source)
                        state.recoveredAt[source] = nil
                        return LiveSourceHealthEntry(
                            source: source,
                            state: .stalled,
                            secondsSinceLastSample: silence
                        )
                    }
                    let recoveredAt = state.recoveredAt[source]
                    let isRecentlyRecovered = recoveredAt.map {
                        timestamp - $0 <= recoveryDisplayDuration
                    } ?? false
                    if !isRecentlyRecovered { state.recoveredAt[source] = nil }
                    return LiveSourceHealthEntry(
                        source: source,
                        state: isRecentlyRecovered ? .recovered : .active,
                        secondsSinceLastSample: silence
                    )
                }
                let age = max(timestamp - state.configuredAt, 0)
                if age > startupGrace { state.stalledSources.insert(source) }
                return LiveSourceHealthEntry(
                    source: source,
                    state: age > startupGrace ? .stalled : .waiting,
                    secondsSinceLastSample: nil
                )
            })
        }
    }
}
