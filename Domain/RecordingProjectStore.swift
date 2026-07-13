import Foundation

struct RecordingProjectManifest: Codable, Equatable {
    let schemaVersion: Int
    let id: UUID
    let createdAt: Date
    var stoppedAt: Date?
    let captureProfile: String
    var displays: [UInt32]
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
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func createProject(displays: [UInt32]) throws -> RecordingProject {
        guard let movies = fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first else {
            throw RecordingProjectStoreError.missingMoviesDirectory
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let rootURL = movies
            .appending(path: "Studio Recorder", directoryHint: .isDirectory)
            .appending(path: "\(timestamp).recordingproject", directoryHint: .isDirectory)
        let rawTracksURL = rootURL.appending(path: "raw-tracks", directoryHint: .isDirectory)

        try fileManager.createDirectory(at: rawTracksURL, withIntermediateDirectories: true)

        let manifest = RecordingProjectManifest(
            schemaVersion: 1,
            id: UUID(),
            createdAt: Date(),
            stoppedAt: nil,
            captureProfile: "1080p-adaptive-30fps",
            displays: displays
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
