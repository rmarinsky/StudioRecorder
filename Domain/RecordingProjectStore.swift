import Foundation

struct RecordingProjectManifest: Codable, Equatable {
    let schemaVersion: Int
    let id: UUID
    let createdAt: Date
    var stoppedAt: Date?
    let captureProfile: String
    var displays: [UInt32]
    let primaryAudioDisplayID: UInt32?
}

struct RecordingProject: Identifiable, Equatable {
    let rootURL: URL
    let manifest: RecordingProjectManifest

    var id: UUID { manifest.id }
    var rawTracksURL: URL { rootURL.appending(path: "raw-tracks", directoryHint: .isDirectory) }
    var journalURL: URL { rootURL.appending(path: "journal.ndjson") }

    func rawScreenURL(for displayID: UInt32) -> URL {
        rawTracksURL.appending(path: "screen-\(displayID).mov")
    }
}

struct InterruptedRecordingProject: Identifiable, Equatable {
    let rootURL: URL
    let createdAt: Date
    let displays: [UInt32]

    var id: URL { rootURL }
}

private struct ProjectJournalEntry: Codable {
    let timestamp: Date
    let kind: String
    let displayID: UInt32?
    let detail: String?
}

enum RecordingProjectStoreError: LocalizedError {
    case missingMoviesDirectory

    var errorDescription: String? {
        switch self {
        case .missingMoviesDirectory:
            "Studio Recorder could not locate the Movies directory."
        }
    }
}

@MainActor
final class RecordingProjectStore {
    private let fileManager: FileManager
    private let baseDirectory: URL?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default, baseDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.baseDirectory = baseDirectory
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func createProject(displays: [UInt32], primaryAudioDisplayID: UInt32?) throws -> RecordingProject {
        let projectsDirectory = try resolvedProjectsDirectory()

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let rootURL = projectsDirectory
            .appending(path: "\(timestamp)-\(UUID().uuidString.prefix(8)).recordingproject", directoryHint: .isDirectory)
        let rawTracksURL = rootURL.appending(path: "raw-tracks", directoryHint: .isDirectory)

        try fileManager.createDirectory(at: rawTracksURL, withIntermediateDirectories: true)

        let manifest = RecordingProjectManifest(
            schemaVersion: 1,
            id: UUID(),
            createdAt: Date(),
            stoppedAt: nil,
            captureProfile: "1080p-adaptive-30fps",
            displays: displays,
            primaryAudioDisplayID: primaryAudioDisplayID
        )
        let project = RecordingProject(rootURL: rootURL, manifest: manifest)
        try write(manifest, to: rootURL.appending(path: "manifest.json"))
        try appendJournal(kind: "project-created", displayID: nil, detail: "Capture profile: \(manifest.captureProfile)", to: project)
        return project
    }

    func markStarted(displayID: UInt32, in project: RecordingProject) throws {
        try appendJournal(kind: "track-started", displayID: displayID, detail: nil, to: project)
    }

    func markFinished(displayID: UInt32, in project: RecordingProject) throws {
        try appendJournal(kind: "track-finished", displayID: displayID, detail: nil, to: project)
    }

    func markFailure(displayID: UInt32?, detail: String, in project: RecordingProject) throws {
        try appendJournal(kind: "track-failed", displayID: displayID, detail: detail, to: project)
    }

    func close(_ project: RecordingProject) throws {
        var manifest = project.manifest
        manifest.stoppedAt = Date()
        try write(manifest, to: project.rootURL.appending(path: "manifest.json"))
        try appendJournal(kind: "project-closed", displayID: nil, detail: nil, to: project)
    }

    func markInterrupted(_ project: RecordingProject, detail: String) throws {
        try appendJournal(kind: "project-interrupted", displayID: nil, detail: detail, to: project)
    }

    func interruptedProjects() -> [InterruptedRecordingProject] {
        guard let projectsDirectory = try? resolvedProjectsDirectory(),
              let urls = try? fileManager.contentsOfDirectory(
                at: projectsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        return urls.compactMap { url in
            guard url.pathExtension == "recordingproject",
                  let data = try? Data(contentsOf: url.appending(path: "manifest.json")),
                  let manifest = try? decoder.decode(RecordingProjectManifest.self, from: data),
                  manifest.stoppedAt == nil else {
                return nil
            }
            return InterruptedRecordingProject(rootURL: url, createdAt: manifest.createdAt, displays: manifest.displays)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    private func resolvedProjectsDirectory() throws -> URL {
        if let baseDirectory {
            return baseDirectory
        }
        guard let movies = fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first else {
            throw RecordingProjectStoreError.missingMoviesDirectory
        }
        return movies.appending(path: "Studio Recorder", directoryHint: .isDirectory)
    }

    private func appendJournal(kind: String, displayID: UInt32?, detail: String?, to project: RecordingProject) throws {
        let entry = ProjectJournalEntry(timestamp: Date(), kind: kind, displayID: displayID, detail: detail)
        let data = try encoder.encode(entry) + Data([0x0A])
        if fileManager.fileExists(atPath: project.journalURL.path) {
            let handle = try FileHandle(forWritingTo: project.journalURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: project.journalURL, options: .atomic)
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
