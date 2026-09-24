import AVFoundation
import Foundation

enum RecordingProjectLifecycle: String, Codable, Equatable, Sendable {
    case recording
    case finalizing
    case finalized
    case recovered
    case needsRecovery
    case unreadable
}

enum RecordingJobKind: String, Codable, Sendable {
    case finalization
    case export
    case transcription
}

enum RecordingJobState: String, Codable, Sendable {
    case queued
    case running
    case failed
    case completed
}

struct RecordingJob: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let projectID: UUID
    let kind: RecordingJobKind
    var state: RecordingJobState
    var stage: String
    var progress: Double
    var failure: String?
    var attempt: Int
    var updatedAt: Date

    init(id: UUID = UUID(), projectID: UUID, kind: RecordingJobKind) {
        self.id = id
        self.projectID = projectID
        self.kind = kind
        state = .queued
        stage = "Queued"
        progress = 0
        failure = nil
        attempt = 1
        updatedAt = Date()
    }
}

enum RecordingJobQueuePolicy {
    static func nextHeavyJob(
        in jobs: [RecordingJob],
        blockedIDs: Set<UUID> = []
    ) -> RecordingJob? {
        jobs.filter {
            $0.state == .queued
                && ($0.kind == .finalization || $0.kind == .export)
                && !blockedIDs.contains($0.id)
        }.min {
            $0.updatedAt == $1.updatedAt
                ? $0.id.uuidString < $1.id.uuidString
                : $0.updatedAt < $1.updatedAt
        }
    }
}

struct ProjectExportRecipe: Codable, Sendable {
    let schemaVersion: Int
    let projectID: UUID
    let editRevision: Date
    let sourceURL: URL
    let destinationURL: URL
    let timeline: ProjectEditTimeline
    let presentation: CapturePresentationSnapshot
    let programSources: ProjectProgramSources?
    let privacyOverlays: [ProjectPrivacyOverlay]
    let audioAdjustment: ProjectAudioAdjustment
    let sourceAudioAdjustments: [ProjectAudioSourceAdjustment]
    let segmentAudioAdjustments: [ProjectSegmentAudioAdjustment]

    init(
        projectID: UUID,
        sourceURL: URL,
        destinationURL: URL,
        timeline: ProjectEditTimeline,
        presentation: CapturePresentationSnapshot,
        programSources: ProjectProgramSources?,
        editRevision: Date = Date(),
        privacyOverlays: [ProjectPrivacyOverlay] = [],
        audioAdjustment: ProjectAudioAdjustment = .unchanged,
        sourceAudioAdjustments: [ProjectAudioSourceAdjustment] = [],
        segmentAudioAdjustments: [ProjectSegmentAudioAdjustment] = []
    ) {
        schemaVersion = 1
        self.projectID = projectID
        self.editRevision = editRevision
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.timeline = timeline
        self.presentation = presentation
        self.programSources = programSources
        self.privacyOverlays = privacyOverlays
        self.audioAdjustment = audioAdjustment
        self.sourceAudioAdjustments = sourceAudioAdjustments
        self.segmentAudioAdjustments = segmentAudioAdjustments
    }
}

enum RecordingJobStoreError: LocalizedError {
    case unsupportedSchema
    case projectMismatch
    case invalidJob
    case jobNotFound
    case notRetryable
    case invalidExport

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema: "This project's jobs were written by an unsupported app version."
        case .projectMismatch: "A job belongs to another recording project."
        case .invalidJob: "The saved job is invalid."
        case .jobNotFound: "The job no longer exists."
        case .notRetryable: "Only failed jobs can be retried."
        case .invalidExport: "The saved export request is invalid or references media outside this project."
        }
    }
}

final class RecordingJobStore {
    private struct Document: Codable {
        let schemaVersion: Int
        var jobs: [RecordingJob]
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func load(in project: RecordingProject) throws -> [RecordingJob] {
        let url = project.rootURL.appending(path: "jobs.json")
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard document.schemaVersion == 1 else { throw RecordingJobStoreError.unsupportedSchema }
        guard document.jobs.allSatisfy({ $0.projectID == project.id }) else {
            throw RecordingJobStoreError.projectMismatch
        }
        guard document.jobs.allSatisfy({ $0.progress.isFinite && (0...1).contains($0.progress) && $0.attempt > 0 }),
              Set(document.jobs.map(\.id)).count == document.jobs.count else {
            throw RecordingJobStoreError.invalidJob
        }
        return document.jobs
    }

    func save(_ job: RecordingJob, in project: RecordingProject) throws {
        guard job.projectID == project.id else { throw RecordingJobStoreError.projectMismatch }
        guard job.progress.isFinite, (0...1).contains(job.progress), job.attempt > 0 else {
            throw RecordingJobStoreError.invalidJob
        }
        var jobs = try load(in: project)
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.append(job)
        }
        try JSONEncoder().encode(Document(schemaVersion: 1, jobs: jobs))
            .write(to: project.rootURL.appending(path: "jobs.json"), options: .atomic)
    }

    func saveExport(_ recipe: ProjectExportRecipe, for job: RecordingJob, in project: RecordingProject) throws {
        guard job.kind == .export else { throw RecordingJobStoreError.invalidExport }
        try validateExport(recipe, project: project)
        let url = exportURL(for: job, in: project)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(recipe).write(to: url, options: .atomic)
    }

    func loadExport(for job: RecordingJob, in project: RecordingProject) throws -> ProjectExportRecipe {
        guard job.kind == .export else { throw RecordingJobStoreError.invalidExport }
        let recipe = try JSONDecoder().decode(
            ProjectExportRecipe.self, from: Data(contentsOf: exportURL(for: job, in: project))
        )
        try validateExport(recipe, project: project)
        return recipe
    }

    private func exportURL(for job: RecordingJob, in project: RecordingProject) -> URL {
        project.rootURL.appending(path: "jobs/export-\(job.id.uuidString).json")
    }

    private func validateExport(_ recipe: ProjectExportRecipe, project: RecordingProject) throws {
        let root = project.rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let sources = [recipe.sourceURL]
            + [recipe.programSources?.screenURL].compactMap { $0 }
            + (recipe.programSources?.screenSources.map(\.url) ?? [])
            + [recipe.programSources?.cameraURL, recipe.programSources?.audioURL].compactMap { $0 }
        let insideProject = sources.allSatisfy {
            $0.isFileURL && $0.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root + "/")
        }
        let destination = recipe.destinationURL.standardizedFileURL.resolvingSymlinksInPath().path
        let validTimeline = recipe.timeline.sourceDuration.isFinite
            && recipe.timeline.sourceDuration > 0
            && recipe.timeline.duration.isFinite
            && recipe.timeline.duration > 0
            && !recipe.timeline.segments.isEmpty
            && recipe.timeline.segments.allSatisfy {
                $0.sourceStart.isFinite && $0.duration.isFinite
                    && $0.sourceStart >= 0 && $0.duration > 0
                    && $0.sourceStart + $0.duration <= recipe.timeline.sourceDuration + 0.001
            }
        guard recipe.schemaVersion == 1,
              recipe.projectID == project.id,
              validTimeline,
              insideProject,
              recipe.destinationURL.isFileURL,
              !recipe.destinationURL.pathComponents.contains(where: { $0.hasSuffix(".recordingproject") }),
              !destination.hasPrefix(root + "/"),
              destination != root else { throw RecordingJobStoreError.invalidExport }
    }

    func retry(jobID: UUID, in project: RecordingProject) throws -> RecordingJob {
        guard var job = try load(in: project).first(where: { $0.id == jobID }) else {
            throw RecordingJobStoreError.jobNotFound
        }
        guard job.state == .failed else { throw RecordingJobStoreError.notRetryable }
        job.state = .queued
        job.stage = "Queued"
        job.progress = 0
        job.failure = nil
        job.attempt += 1
        job.updatedAt = Date()
        try save(job, in: project)
        return job
    }

    func reconcileFinalization(
        in project: RecordingProject,
        projectLifecycle: RecordingProjectLifecycle
    ) throws -> [RecordingJob] {
        var jobs = try load(in: project)
        for index in jobs.indices {
            if jobs[index].kind == .finalization,
               projectLifecycle == .finalized,
               jobs[index].state != .completed {
                jobs[index].state = .completed
                jobs[index].stage = "Completed"
                jobs[index].progress = 1
                jobs[index].failure = nil
            } else if jobs[index].state == .running {
                jobs[index].state = .queued
                jobs[index].stage = "Resuming after interruption"
                jobs[index].progress = 0
                jobs[index].attempt += 1
            } else {
                continue
            }
            jobs[index].updatedAt = Date()
            try save(jobs[index], in: project)
        }
        return jobs
    }
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
    case audio
    case program
}

struct RecordingTrackDescriptor: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let kind: RecordingTrackKind
    let displayID: UInt32?
    let relativePath: String
}

extension RecordingTrackDescriptor {
    static let program = RecordingTrackDescriptor(
        id: "program",
        kind: .program,
        displayID: nil,
        relativePath: "program.mov"
    )

    static let audioStems = RecordingTrackDescriptor(
        id: "audio-stems",
        kind: .audio,
        displayID: nil,
        relativePath: "raw-tracks/audio-stems.mov"
    )

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
    var lifecycle: RecordingProjectLifecycle
    let captureProfile: String
    let sources: [RecordingSourceSnapshot]
    let tracks: [RecordingTrackDescriptor]
    let recoveryReport: RecordingProjectRecoveryReport
    let presentation: CapturePresentationSnapshot?
    let primaryAudioDisplayID: UInt32?
    var recordingName: String? = nil
    var includesCursor = true
    var usesCompositedCursor = false
    var capturesSystemAudio = false
    var capturesMicrophone = false
    var cameraSyncOffset: TimeInterval = 0
    var programDisplayID: UInt32? = nil
    var frameRate = 30

    var id: String { identity.stableID }
    var rootURL: URL { identity.packageURL }
    var isInterrupted: Bool { lifecycle == .needsRecovery || lifecycle == .unreadable }
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
    var tracks: [RecordingTrackDescriptor]?

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
    case recordingPaused
    case recordingResumed
    case finalizationStarted
    case projectClosed
    case projectInterrupted
    case recoveryCompleted

    init?(legacyValue: String) {
        switch legacyValue {
        case "project-created": self = .projectCreated
        case "track-prepared": self = .trackPrepared
        case "track-started": self = .trackStarted
        case "track-finished": self = .trackFinished
        case "track-failed": self = .trackFailed
        case "recording-paused": self = .recordingPaused
        case "recording-resumed": self = .recordingResumed
        case "finalization-started": self = .finalizationStarted
        case "project-closed": self = .projectClosed
        case "project-interrupted": self = .projectInterrupted
        case "recovery-completed": self = .recoveryCompleted
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

enum ProjectTrackTiming {
    static func offset(
        from referenceTrackID: String,
        to trackID: String,
        in events: [ProjectJournalEvent]
    ) -> TimeInterval {
        let referenceStart = events.first {
            $0.kind == .trackStarted && $0.trackID == referenceTrackID
        }?.timestamp
        let trackStart = events.first {
            $0.kind == .trackStarted && $0.trackID == trackID
        }?.timestamp
        guard let referenceStart, let trackStart else { return 0 }
        return trackStart.timeIntervalSince(referenceStart)
    }
}

enum RecordingProjectStoreError: LocalizedError {
    case missingMoviesDirectory
    case missingCaptureDestination
    case missingTrackDescriptor(displayID: UInt32)
    case invalidAudioStemIndex

    var errorDescription: String? {
        switch self {
        case .missingMoviesDirectory:
            "Studio Recorder could not locate the Movies directory."
        case .missingCaptureDestination:
            "Studio Recorder could not resolve the project destination."
        case .missingTrackDescriptor(let displayID):
            "Studio Recorder could not prepare a raw track for display \(displayID)."
        case .invalidAudioStemIndex:
            "Studio Recorder could not persist the audio stem identity index."
        }
    }
}

enum RecordingRecoveryError: LocalizedError, Equatable {
    case notRecoverable
    case noReadableTracks
    case invalidManifest
    case projectChanged

    var errorDescription: String? {
        switch self {
        case .notRecoverable:
            "This project no longer needs recovery."
        case .noReadableTracks:
            "No readable movie tracks were found. Reveal the package to inspect it or move it to Trash."
        case .invalidManifest:
            "The project manifest could not be read safely."
        case .projectChanged:
            "The project changed after it was inspected. Refresh Recovery and try again."
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
        let tracks = request.displaySources.map {
            RecordingTrackDescriptor(
                id: "screen-\($0.id)",
                kind: .screen,
                displayID: $0.id,
                relativePath: "raw-tracks/screen-\($0.id).mov"
            )
        }
        return try createProject(
            request: request,
            tracks: tracks,
            createsRawTracksDirectory: true
        )
    }

    func createProject(request: CaptureRequest) throws -> RecordingProject {
        var tracks = request.displaySources.map {
            RecordingTrackDescriptor(
                id: "screen-\($0.id)",
                kind: .screen,
                displayID: $0.id,
                relativePath: "raw-tracks/screen-\($0.id).mov"
            )
        }
        if request.camera != nil {
            tracks.append(
                RecordingTrackDescriptor(
                    id: "camera",
                    kind: .camera,
                    displayID: nil,
                    relativePath: "raw-tracks/camera.mov"
                )
            )
        }
        if request.audio.capturesSystemAudio || request.audio.capturesMicrophone {
            tracks.append(.audioStems)
        }
        return try createProject(request: request, tracks: tracks, createsRawTracksDirectory: true)
    }

    func createProgramArchiveProject(request: CaptureRequest) throws -> RecordingProject {
        try createProject(
            request: request,
            tracks: [.program],
            createsRawTracksDirectory: false
        )
    }

    private func createProject(
        request: CaptureRequest,
        tracks: [RecordingTrackDescriptor],
        createsRawTracksDirectory: Bool
    ) throws -> RecordingProject {
        let projectsDirectory = baseDirectory ?? request.storage.destinationURL
        guard let projectsDirectory else { throw RecordingProjectStoreError.missingCaptureDestination }
        let createdAt = request.createdAt
        let projectID = request.id
        let timestamp = ISO8601DateFormatter().string(from: createdAt).replacingOccurrences(of: ":", with: "-")
        let rootURL = projectsDirectory.appending(path: "\(timestamp)-\(projectID.uuidString.prefix(8)).recordingproject", directoryHint: .isDirectory)
        if createsRawTracksDirectory {
            let rawTracksURL = rootURL.appending(path: "raw-tracks", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: rawTracksURL, withIntermediateDirectories: true)
        } else {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }

        let displays = request.displaySources.map(\.id)
        let manifest = RecordingProjectManifest(
            schemaVersion: 3,
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

    func markStarted(displayID: UInt32, in project: RecordingProject, timestamp: Date = Date()) throws {
        try markStarted(trackID: project.trackID(for: displayID), in: project, timestamp: timestamp)
    }

    func markFinished(displayID: UInt32, in project: RecordingProject) throws {
        try markFinished(trackID: project.trackID(for: displayID), in: project)
    }

    func markFailure(displayID: UInt32?, detail: String, in project: RecordingProject) throws {
        let trackID = displayID.flatMap(project.trackID(for:))
        try markFailure(trackID: trackID, detail: detail, in: project)
    }

    func markPrepared(trackID: String, in project: RecordingProject) throws {
        try append(.init(kind: .trackPrepared, trackID: trackID), to: project)
    }

    func markStarted(trackID: String?, in project: RecordingProject, timestamp: Date = Date()) throws {
        try append(.init(kind: .trackStarted, trackID: trackID, timestamp: timestamp), to: project)
    }

    func markFinished(trackID: String?, in project: RecordingProject) throws {
        try append(.init(kind: .trackFinished, trackID: trackID), to: project)
    }

    func markFailure(trackID: String?, detail: String, in project: RecordingProject) throws {
        try append(.init(kind: .trackFailed, trackID: trackID, detail: .init(message: detail)), to: project)
    }

    func markRecordingPaused(in project: RecordingProject, timestamp: Date = Date()) throws {
        try append(.init(kind: .recordingPaused, timestamp: timestamp), to: project)
    }

    func markRecordingResumed(in project: RecordingProject, timestamp: Date = Date()) throws {
        try append(.init(kind: .recordingResumed, timestamp: timestamp), to: project)
    }

    func close(
        _ project: RecordingProject,
        replacingTracks tracks: [RecordingTrackDescriptor]? = nil
    ) throws {
        try append(.init(kind: .finalizationStarted), to: project)
        var manifest = project.manifest
        manifest.stoppedAt = Date()
        if let tracks {
            manifest.tracks = tracks
        }
        try write(manifest, to: project.rootURL.appending(path: "manifest.json"))
        try append(.init(kind: .projectClosed), to: project)
    }

    func markInterrupted(_ project: RecordingProject, detail: String) throws {
        try append(.init(kind: .projectInterrupted, detail: .init(message: detail)), to: project)
    }

    func recoverReadableTracks(from snapshot: RecordingProjectSnapshot) throws {
        guard snapshot.lifecycle == .needsRecovery else {
            throw RecordingRecoveryError.notRecoverable
        }
        let manifestURL = snapshot.rootURL.appending(path: "manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              var manifest = try? Self.makeDecoder().decode(RecordingProjectManifest.self, from: data) else {
            throw RecordingRecoveryError.invalidManifest
        }
        if let expectedID = snapshot.identity.manifestID, manifest.id != expectedID {
            throw RecordingRecoveryError.projectChanged
        }
        let readableTrackIDs = Set(snapshot.recoveryReport.tracks.compactMap { track in
            switch track.state {
            case .finalized, .partialReadable:
                track.id
            case .missing, .unreadable, .unknownV1:
                nil
            }
        })
        let recoveredTracks = snapshot.tracks.filter { track in
            readableTrackIDs.contains(track.id) && Self.safeTrackURL(for: track, in: snapshot.rootURL) != nil
        }
        guard !recoveredTracks.isEmpty else {
            throw RecordingRecoveryError.noReadableTracks
        }

        let excludedCount = max(snapshot.tracks.count - recoveredTracks.count, 0)
        manifest.stoppedAt = manifest.stoppedAt ?? Date()
        manifest.tracks = recoveredTracks
        try write(manifest, to: manifestURL)
        try append(
            .init(
                kind: .recoveryCompleted,
                detail: .init(
                    message: "Recovered \(recoveredTracks.count) readable track(s); excluded \(excludedCount) unavailable track(s)."
                )
            ),
            to: RecordingProject(rootURL: snapshot.rootURL, manifest: manifest)
        )
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

    func journalEvents(for project: RecordingProject) -> [ProjectJournalEvent] {
        guard case .success(let events) = Self.readJournal(at: journalURL(for: project)) else { return [] }
        return events
    }

    func writeCursorTimeline(_ timeline: CursorSceneTimeline, in project: RecordingProject) throws {
        let sceneURL = project.rootURL.appending(path: "scene", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: sceneURL, withIntermediateDirectories: true)
        try write(timeline, to: sceneURL.appending(path: "cursor.json"))
    }

    func writeShortcutTimeline(_ timeline: SafeShortcutTimeline, in project: RecordingProject) throws {
        let sceneURL = project.rootURL.appending(path: "scene", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: sceneURL, withIntermediateDirectories: true)
        try write(timeline, to: sceneURL.appending(path: "shortcuts.json"))
    }

    func writeStudioSceneTimeline(_ timeline: StudioSceneTimeline, in project: RecordingProject) throws {
        let sceneURL = project.rootURL.appending(path: "scene", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: sceneURL, withIntermediateDirectories: true)
        try write(timeline, to: sceneURL.appending(path: "layout.json"))
    }

    func writeAudioStemIndex(_ index: ProjectAudioStemIndex, in project: RecordingProject) throws {
        guard index.isValid else { throw RecordingProjectStoreError.invalidAudioStemIndex }
        let url = project.rootURL.appending(path: ProjectAudioStemIndex.filename)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(index, to: url)
    }

    func studioSceneTimeline(in project: RecordingProject) -> StudioSceneTimeline? {
        let url = project.rootURL.appending(path: "scene/layout.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.makeDecoder().decode(StudioSceneTimeline.self, from: data)
    }

    func cursorTimeline(in project: RecordingProject) -> CursorSceneTimeline? {
        let url = project.rootURL.appending(path: "scene/cursor.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.makeDecoder().decode(CursorSceneTimeline.self, from: data)
    }

    func shortcutTimeline(in project: RecordingProject) -> SafeShortcutTimeline? {
        let url = project.rootURL.appending(path: "scene/shortcuts.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.makeDecoder().decode(SafeShortcutTimeline.self, from: data)
    }

    func openProject(at rootURL: URL, expectedID: UUID) throws -> RecordingProject {
        let data = try Data(contentsOf: rootURL.appending(path: "manifest.json"))
        let manifest = try Self.makeDecoder().decode(RecordingProjectManifest.self, from: data)
        guard manifest.id == expectedID else { throw RecordingJobStoreError.projectMismatch }
        return RecordingProject(rootURL: rootURL, manifest: manifest)
    }

    func restorePauseEdits(from snapshot: RecordingProjectSnapshot) async throws {
        guard let projectID = snapshot.identity.manifestID,
              case .success(let events) = Self.readJournal(
                  at: snapshot.rootURL.appending(path: "journal.ndjson")
              ) else { return }
        let pauseEvents = events.filter {
            $0.kind == .recordingPaused || $0.kind == .recordingResumed
        }
        guard pauseEvents.contains(where: { $0.kind == .recordingPaused }) else { return }

        var pauses = RecordingPauseTimeline()
        for event in pauseEvents {
            let timestamp = event.timestamp.timeIntervalSinceReferenceDate
            switch event.kind {
            case .recordingPaused:
                _ = pauses.pause(at: timestamp)
            case .recordingResumed:
                _ = pauses.resume(at: timestamp)
            default:
                break
            }
        }

        let readableTrackIDs = Set(snapshot.recoveryReport.tracks.compactMap { track in
            switch track.state {
            case .finalized, .partialReadable: track.id
            case .missing, .unreadable, .unknownV1: nil
            }
        })
        var timelines: [ProjectEditTimeline] = []
        for track in snapshot.tracks where track.kind == .screen && readableTrackIDs.contains(track.id) {
            guard let startedAt = events.first(where: {
                $0.kind == .trackStarted && $0.trackID == track.id
            })?.timestamp.timeIntervalSinceReferenceDate else { continue }
            let url = snapshot.rootURL.appending(path: track.relativePath)
            let duration = try await AVURLAsset(url: url).load(.duration).seconds
            guard let timeline = try? pauses.makeEditTimeline(
                trackID: track.id,
                recordingStartedAt: startedAt,
                stoppedAt: startedAt + duration,
                sourceDuration: duration
            ) else { continue }
            timelines.append(timeline)
        }
        guard !timelines.isEmpty else { return }

        let editStore = ProjectEditStore()
        var document = try await editStore.load(
            from: snapshot.rootURL,
            expectedProjectID: projectID
        ) ?? ProjectEditDocument(
            projectID: projectID,
            timelines: [],
            presentation: snapshot.presentation
        )
        for timeline in timelines {
            document.replaceTimeline(timeline)
        }
        try await editStore.save(document, in: snapshot.rootURL)
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
        guard (1...3).contains(manifest.schemaVersion) else {
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
                    ?? manifest.primaryAudioDisplayID,
                recordingName: manifest.captureRequest?.recordingName,
                includesCursor: manifest.captureRequest?.profile.includeCursor ?? true,
                usesCompositedCursor: manifest.captureRequest?.profile.resolvedCursorRendering == .composited,
                capturesSystemAudio: manifest.captureRequest?.audio.capturesSystemAudio ?? false,
                capturesMicrophone: manifest.captureRequest?.audio.capturesMicrophone ?? false,
                cameraSyncOffset: manifest.captureRequest?.profile.resolvedCameraSyncOffset ?? 0,
                programDisplayID: manifest.captureRequest?.profile.programDisplayID,
                frameRate: manifest.captureRequest.map {
                    CaptureDefaults.supportedFrameRates.contains($0.profile.frameRate) ? $0.profile.frameRate : 30
                } ?? 30
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
        guard size > 0, await isReadableMedia(at: url, kind: track.kind) else {
            return .init(descriptor: track, state: .unreadable, fileSize: size)
        }
        return .init(descriptor: track, state: finishedTrackIDs.contains(track.id) ? .finalized : .partialReadable, fileSize: size)
    }

    nonisolated private static func isReadableMedia(
        at url: URL,
        kind: RecordingTrackKind
    ) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isReadable)) == true else { return false }
        guard let duration = try? await asset.load(.duration) else { return false }
        guard duration.isNumeric, duration > .zero else { return false }
        let requiredMediaType: AVMediaType = kind == .audio ? .audio : .video
        guard let tracks = try? await asset.loadTracks(withMediaType: requiredMediaType) else { return false }
        return !tracks.isEmpty
    }

    nonisolated private static func safeTrackURL(for track: RecordingTrackDescriptor, in rootURL: URL) -> URL? {
        let rawTracksURL = rootURL.appending(path: "raw-tracks", directoryHint: .isDirectory).standardizedFileURL
        let candidate = rootURL.appending(path: track.relativePath).standardizedFileURL
        if track.kind == .program {
            let programURL = rootURL.appending(path: RecordingTrackDescriptor.program.relativePath).standardizedFileURL
            return candidate == programURL ? candidate : nil
        }
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
        let allRecoveredTracksReadable = !report.tracks.isEmpty && report.tracks.allSatisfy {
            $0.state == .finalized || $0.state == .partialReadable
        }
        if kinds.contains(.recoveryCompleted), allRecoveredTracksReadable {
            return .recovered
        }
        if kinds.contains(.projectInterrupted) || kinds.contains(.trackFailed) || report.tracks.contains(where: { $0.state == .missing || $0.state == .unreadable || $0.state == .unknownV1 }) {
            return .needsRecovery
        }
        if kinds.contains(.finalizationStarted) || kinds.contains(.trackStarted) || kinds.contains(.projectCreated) {
            return .needsRecovery
        }
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
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }

    nonisolated private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractionalFormatter.date(from: value) {
                return date
            }
            let legacyFormatter = ISO8601DateFormatter()
            legacyFormatter.formatOptions = [.withInternetDateTime]
            guard let date = legacyFormatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 date: \(value)"
                )
            }
            return date
        }
        return decoder
    }
}
