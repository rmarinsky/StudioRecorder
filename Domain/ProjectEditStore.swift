import Foundation

struct ProjectAudioAdjustment: Codable, Equatable, Sendable {
    static let unchanged = Self(gain: 1, isMuted: false)

    var gain: Double
    var isMuted: Bool

    var effectiveGain: Float { isMuted ? 0 : Float(gain) }
    var isUnchanged: Bool { !isMuted && abs(gain - 1) < 0.001 }
    var isPersistable: Bool { gain.isFinite && (0...1).contains(gain) }

    init(gain: Double = 1, isMuted: Bool = false) {
        self.gain = min(max(gain.isFinite ? gain : 1, 0), 1)
        self.isMuted = isMuted
    }

    private enum CodingKeys: String, CodingKey { case gain, isMuted }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gain = try container.decodeIfPresent(Double.self, forKey: .gain) ?? 1
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
    }
}

struct ProjectSegmentAudioAdjustment: Codable, Equatable, Identifiable, Sendable {
    let segmentID: UUID
    var gain: Double
    var isMuted: Bool

    var id: UUID { segmentID }
    var effectiveGain: Float { isMuted ? 0 : Float(gain) }
    var isUnchanged: Bool { !isMuted && abs(gain - 1) < 0.001 }
    var isPersistable: Bool { gain.isFinite && (0...1).contains(gain) }

    init(segmentID: UUID, gain: Double = 1, isMuted: Bool = false) {
        self.segmentID = segmentID
        self.gain = min(max(gain.isFinite ? gain : 1, 0), 1)
        self.isMuted = isMuted
    }

    private enum CodingKeys: String, CodingKey { case segmentID, gain, isMuted }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        segmentID = try container.decode(UUID.self, forKey: .segmentID)
        gain = try container.decodeIfPresent(Double.self, forKey: .gain) ?? 1
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
    }
}

enum ProjectEditStoreError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case projectMismatch
    case invalidTimeline(String)
    case invalidPrivacyOverlay
    case invalidSceneTimeline
    case invalidAudioAdjustment
    case invalidSegmentAudioAdjustment

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            "This edit uses unsupported schema version \(version)."
        case .projectMismatch:
            "The edit document belongs to a different recording project."
        case .invalidTimeline(let trackID):
            "The saved edit for track \(trackID) is invalid."
        case .invalidPrivacyOverlay:
            "A saved privacy overlay is invalid."
        case .invalidSceneTimeline:
            "The saved Scene timeline is invalid."
        case .invalidAudioAdjustment:
            "The saved audio adjustment is invalid."
        case .invalidSegmentAudioAdjustment:
            "A saved segment audio adjustment is invalid."
        }
    }
}

struct ProjectEditDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 6

    let schemaVersion: Int
    let projectID: UUID
    var updatedAt: Date
    var timelines: [ProjectEditTimeline]
    var presentation: CapturePresentationSnapshot?
    var privacyOverlays: [ProjectPrivacyOverlay]
    var sceneTimeline: StudioSceneTimeline?
    var audioAdjustment: ProjectAudioAdjustment
    var segmentAudioAdjustments: [ProjectSegmentAudioAdjustment]

    init(
        projectID: UUID,
        updatedAt: Date = Date(),
        timelines: [ProjectEditTimeline],
        presentation: CapturePresentationSnapshot? = nil,
        privacyOverlays: [ProjectPrivacyOverlay] = [],
        sceneTimeline: StudioSceneTimeline? = nil,
        audioAdjustment: ProjectAudioAdjustment = .unchanged,
        segmentAudioAdjustments: [ProjectSegmentAudioAdjustment] = []
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.projectID = projectID
        self.updatedAt = updatedAt
        self.timelines = timelines
        self.presentation = presentation
        self.privacyOverlays = privacyOverlays
        self.sceneTimeline = sceneTimeline
        self.audioAdjustment = audioAdjustment
        self.segmentAudioAdjustments = segmentAudioAdjustments
    }

    func timeline(for trackID: String) -> ProjectEditTimeline? {
        timelines.first { $0.trackID == trackID }
    }

    mutating func replaceTimeline(_ timeline: ProjectEditTimeline, updatedAt: Date = Date()) {
        if let index = timelines.firstIndex(where: { $0.trackID == timeline.trackID }) {
            timelines[index] = timeline
        } else {
            timelines.append(timeline)
        }
        self.updatedAt = updatedAt
    }

    mutating func replacePresentation(
        _ presentation: CapturePresentationSnapshot,
        updatedAt: Date = Date()
    ) {
        self.presentation = presentation.validated()
        self.updatedAt = updatedAt
    }

    mutating func replacePrivacyOverlays(
        _ privacyOverlays: [ProjectPrivacyOverlay],
        updatedAt: Date = Date()
    ) {
        self.privacyOverlays = privacyOverlays
        self.updatedAt = updatedAt
    }

    mutating func replaceSceneTimeline(
        _ sceneTimeline: StudioSceneTimeline?,
        updatedAt: Date = Date()
    ) {
        self.sceneTimeline = sceneTimeline
        self.updatedAt = updatedAt
    }

    mutating func replaceAudioAdjustment(
        _ audioAdjustment: ProjectAudioAdjustment,
        updatedAt: Date = Date()
    ) {
        self.audioAdjustment = ProjectAudioAdjustment(
            gain: audioAdjustment.gain,
            isMuted: audioAdjustment.isMuted
        )
        self.updatedAt = updatedAt
    }

    mutating func replaceSegmentAudioAdjustment(
        _ adjustment: ProjectSegmentAudioAdjustment,
        updatedAt: Date = Date()
    ) {
        segmentAudioAdjustments.removeAll { $0.segmentID == adjustment.segmentID }
        if !adjustment.isUnchanged { segmentAudioAdjustments.append(adjustment) }
        self.updatedAt = updatedAt
    }

    mutating func retainSegmentAudioAdjustments(for segmentIDs: Set<UUID>, updatedAt: Date = Date()) {
        segmentAudioAdjustments.removeAll { !segmentIDs.contains($0.segmentID) }
        self.updatedAt = updatedAt
    }

    func segmentAudioAdjustment(for segmentID: UUID) -> ProjectSegmentAudioAdjustment {
        segmentAudioAdjustments.first { $0.segmentID == segmentID }
            ?? ProjectSegmentAudioAdjustment(segmentID: segmentID)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, projectID, updatedAt, timelines, presentation, privacyOverlays, sceneTimeline,
             audioAdjustment, segmentAudioAdjustments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        projectID = try container.decode(UUID.self, forKey: .projectID)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        timelines = try container.decode([ProjectEditTimeline].self, forKey: .timelines)
        presentation = try container.decodeIfPresent(CapturePresentationSnapshot.self, forKey: .presentation)
        privacyOverlays = try container.decodeIfPresent([ProjectPrivacyOverlay].self, forKey: .privacyOverlays) ?? []
        sceneTimeline = try container.decodeIfPresent(StudioSceneTimeline.self, forKey: .sceneTimeline)
        audioAdjustment = try container.decodeIfPresent(
            ProjectAudioAdjustment.self,
            forKey: .audioAdjustment
        ) ?? .unchanged
        segmentAudioAdjustments = try container.decodeIfPresent(
            [ProjectSegmentAudioAdjustment].self,
            forKey: .segmentAudioAdjustments
        ) ?? []
    }
}

actor ProjectEditStore {
    static let filename = "edit.json"

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func load(from projectRootURL: URL, expectedProjectID: UUID) throws -> ProjectEditDocument? {
        let url = editURL(in: projectRootURL)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let document = try decoder.decode(ProjectEditDocument.self, from: Data(contentsOf: url))
        try validate(document, expectedProjectID: expectedProjectID, allowsLegacy: true)
        guard document.schemaVersion < ProjectEditDocument.currentSchemaVersion else { return document }
        return ProjectEditDocument(
            projectID: document.projectID,
            updatedAt: document.updatedAt,
            timelines: document.timelines,
            presentation: document.presentation,
            privacyOverlays: document.privacyOverlays,
            sceneTimeline: document.sceneTimeline,
            audioAdjustment: document.audioAdjustment,
            segmentAudioAdjustments: document.segmentAudioAdjustments
        )
    }

    func save(_ document: ProjectEditDocument, in projectRootURL: URL) throws {
        try validate(document, expectedProjectID: document.projectID, allowsLegacy: false)
        try encoder.encode(document).write(to: editURL(in: projectRootURL), options: .atomic)
    }

    func editURL(in projectRootURL: URL) -> URL {
        projectRootURL.appending(path: Self.filename)
    }

    private func validate(
        _ document: ProjectEditDocument,
        expectedProjectID: UUID,
        allowsLegacy: Bool
    ) throws {
        guard document.schemaVersion == ProjectEditDocument.currentSchemaVersion
                || (allowsLegacy && (1...5).contains(document.schemaVersion)) else {
            throw ProjectEditStoreError.unsupportedSchema(document.schemaVersion)
        }
        guard document.projectID == expectedProjectID else {
            throw ProjectEditStoreError.projectMismatch
        }
        var seenTrackIDs: Set<String> = []
        for timeline in document.timelines {
            guard timeline.schemaVersion == ProjectEditTimeline.currentSchemaVersion,
                  !timeline.trackID.isEmpty,
                  seenTrackIDs.insert(timeline.trackID).inserted,
                  timeline.sourceDuration.isFinite,
                  timeline.sourceDuration > 0,
                  !timeline.segments.isEmpty,
                  timeline.segments.allSatisfy({ segment in
                      segment.sourceStart.isFinite
                          && segment.sourceStart >= 0
                          && segment.duration.isFinite
                          && segment.duration > 0
                          && segment.sourceStart + segment.duration <= timeline.sourceDuration + 0.001
                  }),
                  Set(timeline.segments.map(\.id)).count == timeline.segments.count else {
                throw ProjectEditStoreError.invalidTimeline(timeline.trackID)
            }
        }
        let allSegmentIDs = document.timelines.flatMap { $0.segments.map(\.id) }
        guard Set(allSegmentIDs).count == allSegmentIDs.count else {
            throw ProjectEditStoreError.invalidSegmentAudioAdjustment
        }
        guard document.privacyOverlays.allSatisfy(\.isPersistable),
              Set(document.privacyOverlays.map(\.id)).count == document.privacyOverlays.count else {
            throw ProjectEditStoreError.invalidPrivacyOverlay
        }
        guard document.audioAdjustment.isPersistable else {
            throw ProjectEditStoreError.invalidAudioAdjustment
        }
        let segmentIDs = Set(allSegmentIDs)
        guard document.segmentAudioAdjustments.allSatisfy({
            $0.isPersistable && segmentIDs.contains($0.segmentID) && !$0.isUnchanged
        }), Set(document.segmentAudioAdjustments.map(\.segmentID)).count == document.segmentAudioAdjustments.count else {
            throw ProjectEditStoreError.invalidSegmentAudioAdjustment
        }
        if let sceneTimeline = document.sceneTimeline {
            guard sceneTimeline.schemaVersion == 1,
                  !sceneTimeline.transitions.isEmpty,
                  sceneTimeline.transitions.first?.sourceTime == 0,
                  sceneTimeline.transitions.allSatisfy({ $0.sourceTime.isFinite && $0.sourceTime >= 0 }),
                  zip(sceneTimeline.transitions, sceneTimeline.transitions.dropFirst())
                    .allSatisfy({ pair in pair.0.sourceTime <= pair.1.sourceTime }) else {
                throw ProjectEditStoreError.invalidSceneTimeline
            }
        }
    }
}
