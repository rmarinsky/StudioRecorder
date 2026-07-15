import Combine
import Foundation

struct StudioScenePreset: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var presentation: CapturePresentationSnapshot

    init(id: UUID = UUID(), presentation: CapturePresentationSnapshot) {
        self.id = id
        self.presentation = presentation.validated()
    }

    var name: String { presentation.resolvedName }
}

private struct StudioSceneLibraryDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    var scenes: [StudioScenePreset]
}

enum StudioSceneLibraryError: LocalizedError, Equatable {
    case unreadableExistingLibrary
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadableExistingLibrary:
            "The existing scene library could not be read safely. It was preserved and was not overwritten."
        case .saveFailed(let message):
            "The scene library could not be saved. \(message)"
        }
    }
}

@MainActor
final class StudioSceneLibraryStore: ObservableObject {
    @Published private(set) var scenes: [StudioScenePreset]

    private let fileURL: URL
    private let fileManager: FileManager
    private let hasUnreadableExistingLibrary: Bool

    init(
        fileURL: URL = StudioSceneLibraryStore.defaultFileURL(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        if let data = try? Data(contentsOf: fileURL),
           let document = try? JSONDecoder().decode(StudioSceneLibraryDocument.self, from: data),
           document.schemaVersion == 1 {
            scenes = document.scenes.map {
                StudioScenePreset(id: $0.id, presentation: $0.presentation)
            }
            hasUnreadableExistingLibrary = false
        } else {
            scenes = []
            hasUnreadableExistingLibrary = fileManager.fileExists(atPath: fileURL.path)
        }
    }

    func save(_ scene: StudioScenePreset) throws {
        guard !hasUnreadableExistingLibrary else {
            throw StudioSceneLibraryError.unreadableExistingLibrary
        }
        var next = scenes
        if let index = next.firstIndex(where: { $0.id == scene.id }) {
            next[index] = StudioScenePreset(id: scene.id, presentation: scene.presentation)
        } else {
            next.append(StudioScenePreset(id: scene.id, presentation: scene.presentation))
        }
        try persist(next)
        scenes = next
    }

    func remove(_ id: UUID) throws {
        guard !hasUnreadableExistingLibrary else {
            throw StudioSceneLibraryError.unreadableExistingLibrary
        }
        let next = scenes.filter { $0.id != id }
        try persist(next)
        scenes = next
    }

    func scene(id: UUID?) -> StudioScenePreset? {
        guard let id else { return nil }
        return scenes.first { $0.id == id }
    }

    private func persist(_ scenes: [StudioScenePreset]) throws {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(
                StudioSceneLibraryDocument(schemaVersion: 1, scenes: scenes)
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw StudioSceneLibraryError.saveFailed(error.localizedDescription)
        }
    }

    nonisolated private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return base
            .appending(path: "Studio Recorder", directoryHint: .isDirectory)
            .appending(path: "scenes.json")
    }
}

struct StudioSceneTransition: Codable, Equatable, Sendable {
    let sourceTime: TimeInterval
    let presentation: CapturePresentationSnapshot
}

struct StudioSceneTimeline: Codable, Equatable, Sendable {
    let schemaVersion: Int
    private(set) var transitions: [StudioSceneTransition]

    var hasSceneSwitches: Bool { transitions.count > 1 }

    init(initialPresentation: CapturePresentationSnapshot) {
        schemaVersion = 1
        transitions = [
            StudioSceneTransition(sourceTime: 0, presentation: initialPresentation.validated()),
        ]
    }

    mutating func append(_ presentation: CapturePresentationSnapshot, at sourceTime: TimeInterval) {
        guard sourceTime.isFinite, sourceTime >= 0 else { return }
        let transition = StudioSceneTransition(
            sourceTime: sourceTime,
            presentation: presentation.validated()
        )
        if let last = transitions.last, abs(last.sourceTime - sourceTime) < 0.001 {
            transitions[transitions.count - 1] = transition
        } else if transitions.last?.presentation != transition.presentation {
            transitions.append(transition)
            transitions.sort { $0.sourceTime < $1.sourceTime }
        }
    }

    mutating func offsetSceneSwitches(by offset: TimeInterval) {
        guard offset.isFinite, abs(offset) >= 0.001, transitions.count > 1 else { return }
        transitions = transitions.enumerated().map { index, transition in
            guard index > 0 else { return transition }
            return StudioSceneTransition(
                sourceTime: max(transition.sourceTime + offset, 0),
                presentation: transition.presentation
            )
        }
        transitions.sort { $0.sourceTime < $1.sourceTime }
    }

    func presentation(at sourceTime: TimeInterval) -> CapturePresentationSnapshot {
        transitions.last { $0.sourceTime <= sourceTime }?.presentation
            ?? transitions.first?.presentation
            ?? .default
    }
}

enum StudioSceneLiveIncompatibility: Equatable, Sendable {
    case canvasChanged
    case cameraUnavailable
    case cursorTelemetryUnavailable
    case captureRegionChanged

    var message: String {
        switch self {
        case .canvasChanged:
            "Stop the session before changing output dimensions."
        case .cameraUnavailable:
            "This scene needs a camera that was not enabled when the session started."
        case .cursorTelemetryUnavailable:
            "Follow Cursor was not enabled when this recording started."
        case .captureRegionChanged:
            "This recording started with a fixed source region that cannot change safely."
        }
    }
}

struct StudioSceneLiveContract: Equatable, Sendable {
    let initialPresentation: CapturePresentationSnapshot
    let capturesCamera: Bool
    let recordsCursorTelemetry: Bool

    func incompatibility(
        for candidate: CapturePresentationSnapshot
    ) -> StudioSceneLiveIncompatibility? {
        let initial = initialPresentation.validated()
        let candidate = candidate.validated()
        guard candidate.canvas == initial.canvas else { return .canvasChanged }
        if candidate.camera.isVisible, !capturesCamera { return .cameraUnavailable }
        if candidate.framing.mode == .followCursor, !recordsCursorTelemetry {
            return .cursorTelemetryUnavailable
        }
        if initial.framing.mode == .fixedRegion,
           candidate.framing != initial.framing {
            return .captureRegionChanged
        }
        return nil
    }
}
