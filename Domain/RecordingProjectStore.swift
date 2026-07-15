import AVFoundation
import Foundation

enum RecordingProjectLifecycle: String, Codable, Equatable, Sendable {
    case recording
    case finalizing
    case finalized
    case needsRecovery
    case unreadable
}

enum RecordingSourceMetadataState: String, Codable, Equatable, Sendable {
    case known
    case unknown
}

struct RecordingSourceSnapshot: Codable, Equatable, Sendable {
    let displayID: UInt32?
    let name: String
    let pixelWidth: Int?
    let pixelHeight: Int?
    let metadataState: RecordingSourceMetadataState

    static func display(id: UInt32, name: String = "Unknown display", pixelWidth: Int? = nil, pixelHeight: Int? = nil) -> Self {
        Self(
            displayID: id,
            name: name,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            metadataState: name == "Unknown display" ? .unknown : .known
        )
    }
}

typealias CaptureRequestSnapshot = CaptureRequest

enum RecordingTrackKind: String, Codable, Equatable, Sendable {
    case screen
    case camera
}

struct RecordingTrackDescriptor: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let kind: RecordingTrackKind
    let displayID: UInt32?
    let relativePath: String
}

enum RecordingTrackRecoveryState: String, Equatable, Sendable {
    case finalized
    case partialReadable
    case missing
    case unreadable
    case unknownV1
}

struct RecordingTrackRecoverySnapshot: Equatable, Sendable, Identifiable {
    let descriptor: RecordingTrackDescriptor
    let state: RecordingTrackRecoveryState
    let fileSize: Int64?

    var id: String { descriptor.id }
}

struct RecordingProjectRecoveryReport: Equatable, Sendable {
    let tracks: [RecordingTrackRecoverySnapshot]
    let diagnostics: [String]

    var needsReview: Bool {
        tracks.contains { $0.state != .finalized } || !diagnostics.isEmpty
    }
}

struct RecordingProjectIdentity: Equatable, Sendable {
    let packageURL: URL
    let manifestID: UUID?

    var stableID: String {
        manifestID?.uuidString ?? packageURL.standardizedFileURL.path
    }
}

struct RecordingProjectSnapshot: Identifiable, Equatable, Sendable {
    let identity: RecordingProjectIdentity
    let createdAt: Date
    let stoppedAt: Date?
    let lifecycle: RecordingProjectLifecycle
    let captureProfile: String
    let sources: [RecordingSourceSnapshot]
    let tracks: [RecordingTrackDescriptor]
    let recoveryReport: RecordingProjectRecoveryReport
    let presentation: CapturePresentationSnapshot?
    let primaryAudioDisplayID: UInt32?

    var id: String { identity.stableID }
    var rootURL: URL { identity.packageURL }
    var isInterrupted: Bool { lifecycle == .needsRecovery }
    var displayCount: Int { sources.count }
}

struct RecordingProjectManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let createdAt: Date
    var stoppedAt: Date?
    let captureProfile: String
    let displays: [UInt32]
    let primaryAudioDisplayID: UInt32?
    let captureRequest: CaptureRequestSnapshot?
    let appVersion: String?
    let appBuild: String?
    let tracks: [RecordingTrackDescriptor]?

    init(
        schemaVersion: Int,
        id: UUID,
        createdAt: Date,
        stoppedAt: Date?,
        captureProfile: String,
        displays: [UInt32],
        primaryAudioDisplayID: UInt32?,
        captureRequest: CaptureRequestSnapshot? = nil,
        appVersion: String? = nil,
        appBuild: String? = nil,
        tracks: [RecordingTrackDescriptor]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.stoppedAt = stoppedAt
        self.captureProfile = captureProfile
        self.displays = displays
        self.primaryAudioDisplayID = primaryAudioDisplayID
        self.captureRequest = captureRequest
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.tracks = tracks
    }
}

struct RecordingProject: Identifiable, Equatable, Sendable {
    let rootURL: URL
    let manifest: RecordingProjectManifest

    var id: UUID { manifest.id }

    func trackID(for displayID: UInt32) -> String? {
        manifest.tracks?.first(where: { $0.displayID == displayID })?.id
    }

    func trackID(for kind: RecordingTrackKind) -> String? {
        manifest.tracks?.first(where: { $0.kind == kind })?.id
    }
}

enum ProjectJournalEventKind: String, Codable, Equatable, Sendable {
    case projectCreated
    case trackPrepared
    case trackStarted
    case trackFinished
    case trackFailed
    case finalizationStarted
    case projectClosed
    case projectInterrupted

    init?(legacyValue: String) {
        switch legacyValue {
        case "project-created": self = .projectCreated
        case "track-prepared": self = .trackPrepared
        case "track-started": self = .trackStarted
        case "track-finished": self = .trackFinished
        case "track-failed": self = .trackFailed
        case "finalization-started": self = .finalizationStarted
        case "project-closed": self = .projectClosed
        case "project-interrupted": self = .projectInterrupted
        default: return nil
        }
    }
}

struct ProjectJournalEventDetail: Codable, Equatable, Sendable {
    let message: String?
    let captureProfile: String?

    init(message: String? = nil, captureProfile: String? = nil) {
        self.message = message
        self.captureProfile = captureProfile
    }
}

struct ProjectJournalEvent: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let timestamp: Date
    let kind: ProjectJournalEventKind
    let trackID: String?
    let detail: ProjectJournalEventDetail?

    init(
        kind: ProjectJournalEventKind,
        trackID: String? = nil,
        detail: ProjectJournalEventDetail? = nil,
        timestamp: Date = Date()
    ) {
        schemaVersion = 2
        self.timestamp = timestamp
        self.kind = kind
        self.trackID = trackID
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, timestamp, kind, trackID, detail, displayID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard schemaVersion == 1 || schemaVersion == 2 else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container, debugDescription: "Unsupported journal schema \(schemaVersion)")
        }
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        let rawKind = try container.decode(String.self, forKey: .kind)
        guard let kind = ProjectJournalEventKind(rawValue: rawKind) ?? ProjectJournalEventKind(legacyValue: rawKind) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown journal event kind: \(rawKind)")
        }
        self.kind = kind
        if let trackID = try container.decodeIfPresent(String.self, forKey: .trackID) {
            self.trackID = trackID
        } else if let displayID = try container.decodeIfPresent(UInt32.self, forKey: .displayID) {
            self.trackID = "screen-\(displayID)"
        } else {
            trackID = nil
        }
        if let detail = try? container.decodeIfPresent(ProjectJournalEventDetail.self, forKey: .detail) {
            self.detail = detail
        } else if let legacyDetail = try? container.decodeIfPresent(String.self, forKey: .detail) {
            self.detail = .init(message: legacyDetail)
        } else {
            self.detail = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(kind.rawValue, forKey: .kind)
        try container.encodeIfPresent(trackID, forKey: .trackID)
        try container.encodeIfPresent(detail, forKey: .detail)
    }
}

enum RecordingProjectStoreError: LocalizedError {
    case missingMoviesDirectory
    case missingCaptureDestination
    case missingTrackDescriptor(displayID: UInt32)

    var errorDescription: String? {
        switch self {
        case .missingMoviesDirectory:
            "Studio Recorder could not locate the Movies directory."
        case .missingCaptureDestination:
            "Studio Recorder could not resolve the project destination."
        case .missingTrackDescriptor(let displayID):
            "Studio Recorder could not prepare a raw track for display \(displayID)."
        }
    }
}

@MainActor
final class RecordingProjectStore {
    private let fileManager: FileManager
    private let baseDirectory: URL?
    private let encoder: JSONEncoder

    init(fileManager: FileManager = .default, baseDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.baseDirectory = baseDirectory
        encoder = Self.makeEncoder(prettyPrinted: true)
    }

    func createProject(
        displays: [UInt32],
        primaryAudioDisplayID: UInt32?,
        capturesMicrophone: Bool = true
    ) throws -> RecordingProject {
        try createProject(
            sources: displays.map { RecordingSourceSnapshot.display(id: $0) },
            primaryAudioDisplayID: primaryAudioDisplayID,
            capturesMicrophone: capturesMicrophone
        )
    }

    func createProject(
        sources: [RecordingSourceSnapshot],
        primaryAudioDisplayID: UInt32?,
        capturesMicrophone: Bool = true
    ) throws -> RecordingProject {
        let createdAt = Date()
        let projectID = UUID()
        let request = CaptureRequest(
            id: projectID,
            createdAt: createdAt,
            displaySources: sources.compactMap { source in
                guard let id = source.displayID else { return nil }
                return DisplaySourceSnapshot(
                    id: id,
                    name: source.name,
                    pixelWidth: source.pixelWidth ?? 0,
                    pixelHeight: source.pixelHeight ?? 0,
                    metadataState: source.metadataState
                )
            },
            audio: AudioCaptureSnapshot(
                capturesSystemAudio: primaryAudioDisplayID != nil,
                capturesMicrophone: capturesMicrophone,
                microphone: nil,
                primaryAudioDisplayID: primaryAudioDisplayID,
                excludesStudioRecorderAudio: true
            ),
            profile: CaptureProfileSnapshot(
                frameRate: 30,
                codecPolicy: .automatic,
                includeCursor: true,
                excludeStudioRecorder: true,
                programResolutionTarget: "1920x1080"
            ),
            storage: StorageCaptureSnapshot(
                destinationURL: baseDirectory ?? (try? resolvedProjectsDirectory()),
                destinationBookmarkID: baseDirectory == nil ? "default-movies" : "test-destination",
                fallbackPath: (baseDirectory ?? (try? resolvedProjectsDirectory()))?.path ?? ""
            )
        )
        return try createProject(request: request)
    }

    func createProject(request: CaptureRequest) throws -> RecordingProject {
        let projectsDirectory = baseDirectory ?? request.storage.destinationURL
        guard let projectsDirectory else { throw RecordingProjectStoreError.missingCaptureDestination }
        let createdAt = request.createdAt
        let projectID = request.id
        let timestamp = ISO8601DateFormatter().string(from: createdAt).replacingOccurrences(of: ":", with: "-")
        let rootURL = projectsDirectory.appending(path: "\(timestamp)-\(projectID.uuidString.prefix(8)).recordingproject", directoryHint: .isDirectory)
        let rawTracksURL = rootURL.appending(path: "raw-tracks", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: rawTracksURL, withIntermediateDirectories: true)

        let displays = request.displaySources.map(\.id)
        var tracks = displays.map {
            RecordingTrackDescriptor(id: "screen-\($0)", kind: .screen, displayID: $0, relativePath: "raw-tracks/screen-\($0).mov")
        }
        if request.camera != nil {
            tracks.append(
                RecordingTrackDescriptor(id: "camera", kind: .camera, displayID: nil, relativePath: "raw-tracks/camera.mov")
            )
        }
        let manifest = RecordingProjectManifest(
            schemaVersion: 2,
            id: projectID,
            createdAt: createdAt,
            stoppedAt: nil,
            captureProfile: request.captureProfile,
            displays: displays,
            primaryAudioDisplayID: request.primaryAudioDisplayID,
            captureRequest: request,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
            tracks: tracks
        )
        let project = RecordingProject(rootURL: rootURL, manifest: manifest)
        try write(manifest, to: rootURL.appending(path: "manifest.json"))
        try append(.init(kind: .projectCreated, detail: .init(captureProfile: manifest.captureProfile)), to: project)
        for track in tracks {
            try append(.init(kind: .trackPrepared, trackID: track.id), to: project)
        }
        return project
    }

    func markStarted(displayID: UInt32, in project: RecordingProject) throws {
        try markStarted(trackID: project.trackID(for: displayID), in: project)
    }

    func markFinished(displayID: UInt32, in project: RecordingProject) throws {
        try markFinished(trackID: project.trackID(for: displayID), in: project)
    }

    func markFailure(displayID: UInt32?, detail: String, in project: RecordingProject) throws {
        let trackID = displayID.flatMap(project.trackID(for:))
        try markFailure(trackID: trackID, detail: detail, in: project)
    }

    func markStarted(trackID: String?, in project: RecordingProject) throws {
        try append(.init(kind: .trackStarted, trackID: trackID), to: project)
    }

    func markFinished(trackID: String?, in project: RecordingProject) throws {
        try append(.init(kind: .trackFinished, trackID: trackID), to: project)
    }

    func markFailure(trackID: String?, detail: String, in project: RecordingProject) throws {
        try append(.init(kind: .trackFailed, trackID: trackID, detail: .init(message: detail)), to: project)
    }

    func close(_ project: RecordingProject) throws {
        try append(.init(kind: .finalizationStarted), to: project)
        var manifest = project.manifest
        manifest.stoppedAt = Date()
        try write(manifest, to: project.rootURL.appending(path: "manifest.json"))
        try append(.init(kind: .projectClosed), to: project)
    }

    func markInterrupted(_ project: RecordingProject, detail: String) throws {
        try append(.init(kind: .projectInterrupted, detail: .init(message: detail)), to: project)
    }

    func rawTrackURL(for displayID: UInt32, in project: RecordingProject) -> URL? {
        rawTrackURL(for: project.trackID(for: displayID), in: project)
    }

    func rawTrackURL(for trackID: String, in project: RecordingProject) -> URL? {
        rawTrackURL(for: Optional(trackID), in: project)
    }

    private func rawTrackURL(for trackID: String?, in project: RecordingProject) -> URL? {
        project.manifest.tracks?
            .first(where: { $0.id == trackID })
            .map { project.rootURL.appending(path: $0.relativePath) }
    }

    func journalURL(for project: RecordingProject) -> URL {
        project.rootURL.appending(path: "journal.ndjson")
    }

    func writeCursorTimeline(_ timeline: CursorSceneTimeline, in project: RecordingProject) throws {
        let sceneURL = project.rootURL.appending(path: "scene", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: sceneURL, withIntermediateDirectories: true)
        try write(timeline, to: sceneURL.appending(path: "cursor.json"))
    }

    func discoverProjects(in additionalDirectories: [URL] = []) async -> [RecordingProjectSnapshot] {
        guard let defaultDirectory = try? resolvedProjectsDirectory() else { return [] }
        var seenPaths: Set<String> = []
        let directories = ([defaultDirectory] + additionalDirectories.sorted { $0.path < $1.path }).filter {
            seenPaths.insert($0.standardizedFileURL.path).inserted
        }
        var discovered: [RecordingProjectSnapshot] = []
        for directory in directories {
            discovered.append(contentsOf: await Self.scanProjects(in: directory))
        }
        var seenProjectIDs: Set<String> = []
        return discovered
            .filter { seenProjectIDs.insert($0.id).inserted }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.rootURL.path < $1.rootURL.path
            }
    }

    private func resolvedProjectsDirectory() throws -> URL {
        if let baseDirectory { return baseDirectory }
        guard let movies = fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first else {
            throw RecordingProjectStoreError.missingMoviesDirectory
        }
        return movies.appending(path: "Studio Recorder", directoryHint: .isDirectory)
    }

    private func append(_ event: ProjectJournalEvent, to project: RecordingProject) throws {
        let data = try Self.makeEncoder(prettyPrinted: false).encode(event) + Data([0x0A])
        let journalURL = journalURL(for: project)
        if fileManager.fileExists(atPath: journalURL.path) {
            let handle = try FileHandle(forWritingTo: journalURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: journalURL, options: .atomic)
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    nonisolated private static func scanProjects(in directory: URL) async -> [RecordingProjectSnapshot] {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var snapshots: [RecordingProjectSnapshot] = []
        for url in urls where url.pathExtension == "recordingproject" {
            snapshots.append(await normalizePackage(at: url, fileManager: fileManager))
        }
        return snapshots.sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.rootURL.path < $1.rootURL.path
            }
    }

    nonisolated private static func normalizePackage(at rootURL: URL, fileManager: FileManager) async -> RecordingProjectSnapshot {
        let fallbackDate = (try? rootURL.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        let manifestURL = rootURL.appending(path: "manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            return unreadableSnapshot(at: rootURL, createdAt: fallbackDate, diagnostic: "Missing manifest.json")
        }
        guard let manifest = try? makeDecoder().decode(RecordingProjectManifest.self, from: data) else {
            return unreadableSnapshot(at: rootURL, createdAt: fallbackDate, diagnostic: "Unreadable manifest.json")
        }
        guard manifest.schemaVersion == 1 || manifest.schemaVersion == 2 else {
            return unreadableSnapshot(at: rootURL, createdAt: manifest.createdAt, manifestID: manifest.id, diagnostic: "Unsupported manifest schema \(manifest.schemaVersion)")
        }

        switch readJournal(at: rootURL.appending(path: "journal.ndjson")) {
        case .failure(let diagnostic):
            return unreadableSnapshot(at: rootURL, createdAt: manifest.createdAt, manifestID: manifest.id, diagnostic: diagnostic)
        case .success(let events):
            let sources = manifest.captureRequest?.sources ?? manifest.displays.map { RecordingSourceSnapshot.display(id: $0) }
            let tracks = manifest.tracks ?? manifest.displays.map {
                RecordingTrackDescriptor(id: "screen-\($0)", kind: .screen, displayID: $0, relativePath: "raw-tracks/screen-\($0).mov")
            }
            let finishedTrackIDs = Set(events.filter { $0.kind == .trackFinished }.compactMap(\.trackID))
            var recoveryTracks: [RecordingTrackRecoverySnapshot] = []
            for track in tracks {
                recoveryTracks.append(await inspect(
                    track: track,
                    in: rootURL,
                    isV1: manifest.schemaVersion == 1,
                    finishedTrackIDs: finishedTrackIDs,
                    fileManager: fileManager
                ))
            }
            let diagnostics = events.compactMap { event -> String? in
                guard event.kind == .trackFailed || event.kind == .projectInterrupted else { return nil }
                return event.detail?.message ?? event.kind.rawValue
            }
            let report = RecordingProjectRecoveryReport(tracks: recoveryTracks, diagnostics: diagnostics)
            let lifecycle = deriveLifecycle(manifest: manifest, events: events, report: report)
            return RecordingProjectSnapshot(
                identity: .init(packageURL: rootURL, manifestID: manifest.id),
                createdAt: manifest.createdAt,
                stoppedAt: manifest.stoppedAt,
                lifecycle: lifecycle,
                captureProfile: manifest.captureRequest?.captureProfile ?? manifest.captureProfile,
                sources: sources,
                tracks: tracks,
                recoveryReport: report,
                presentation: manifest.captureRequest?.presentation,
                primaryAudioDisplayID: manifest.captureRequest?.audio.primaryAudioDisplayID
                    ?? manifest.primaryAudioDisplayID
            )
        }
    }

    private enum JournalReadResult {
        case success([ProjectJournalEvent])
        case failure(String)
    }

    nonisolated private static func readJournal(at url: URL) -> JournalReadResult {
        guard let data = try? Data(contentsOf: url) else { return .success([]) }
        guard let text = String(data: data, encoding: .utf8) else { return .failure("Journal is not UTF-8") }
        let lines = text.split(whereSeparator: \.isNewline)
        var events: [ProjectJournalEvent] = []
        for (index, line) in lines.enumerated() {
            guard let event = try? makeDecoder().decode(ProjectJournalEvent.self, from: Data(line.utf8)) else {
                return .failure("Corrupt journal line \(index + 1)")
            }
            events.append(event)
        }
        return .success(events)
    }

    nonisolated private static func inspect(
        track: RecordingTrackDescriptor,
        in rootURL: URL,
        isV1: Bool,
        finishedTrackIDs: Set<String>,
        fileManager: FileManager
    ) async -> RecordingTrackRecoverySnapshot {
        guard let url = safeTrackURL(for: track, in: rootURL) else {
            return .init(descriptor: track, state: .unreadable, fileSize: nil)
        }
        guard fileManager.fileExists(atPath: url.path) else {
            return .init(descriptor: track, state: isV1 ? .unknownV1 : .missing, fileSize: nil)
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size > 0, await isReadableMedia(at: url) else {
            return .init(descriptor: track, state: .unreadable, fileSize: size)
        }
        return .init(descriptor: track, state: finishedTrackIDs.contains(track.id) ? .finalized : .partialReadable, fileSize: size)
    }

    nonisolated private static func isReadableMedia(at url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isReadable)) == true else { return false }
        guard let duration = try? await asset.load(.duration) else { return false }
        guard duration.isNumeric, duration > .zero else { return false }
        guard let videoTracks = try? await asset.loadTracks(withMediaType: .video) else { return false }
        return !videoTracks.isEmpty
    }

    nonisolated private static func safeTrackURL(for track: RecordingTrackDescriptor, in rootURL: URL) -> URL? {
        let rawTracksURL = rootURL.appending(path: "raw-tracks", directoryHint: .isDirectory).standardizedFileURL
        let candidate = rootURL.appending(path: track.relativePath).standardizedFileURL
        guard candidate.deletingLastPathComponent().standardizedFileURL == rawTracksURL,
              candidate.pathExtension == "mov" else {
            return nil
        }
        return candidate
    }

    nonisolated private static func deriveLifecycle(
        manifest: RecordingProjectManifest,
        events: [ProjectJournalEvent],
        report: RecordingProjectRecoveryReport
    ) -> RecordingProjectLifecycle {
        let kinds = Set(events.map(\.kind))
        let allTracksFinalized = !report.tracks.isEmpty && report.tracks.allSatisfy { $0.state == .finalized }
        if manifest.stoppedAt != nil, kinds.contains(.projectClosed), allTracksFinalized, report.diagnostics.isEmpty {
            return .finalized
        }
        if kinds.contains(.projectInterrupted) || kinds.contains(.trackFailed) || report.tracks.contains(where: { $0.state == .missing || $0.state == .unreadable || $0.state == .unknownV1 }) {
            return .needsRecovery
        }
        if kinds.contains(.finalizationStarted) { return .finalizing }
        if kinds.contains(.trackStarted) || kinds.contains(.projectCreated) { return .recording }
        return .needsRecovery
    }

    nonisolated private static func unreadableSnapshot(at rootURL: URL, createdAt: Date, manifestID: UUID? = nil, diagnostic: String) -> RecordingProjectSnapshot {
        .init(
            identity: .init(packageURL: rootURL, manifestID: manifestID),
            createdAt: createdAt,
            stoppedAt: nil,
            lifecycle: .unreadable,
            captureProfile: "Unknown",
            sources: [],
            tracks: [],
            recoveryReport: .init(tracks: [], diagnostics: [diagnostic]),
            presentation: nil,
            primaryAudioDisplayID: nil
        )
    }

    nonisolated private static func makeEncoder(prettyPrinted: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    nonisolated private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
