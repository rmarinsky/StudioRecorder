import CoreMedia
import Foundation

enum TranscriptTimingStatus: String, Codable, Sendable {
    case aligned
    case uncertain
    case reviewed
}

struct TimedTranscriptWord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let text: String
    let sourceStart: TimeInterval
    let sourceEnd: TimeInterval
    let timingStatus: TranscriptTimingStatus
    let timingModel: String?

    init(
        id: UUID = UUID(),
        text: String,
        sourceStart: TimeInterval,
        sourceEnd: TimeInterval,
        timingStatus: TranscriptTimingStatus,
        timingModel: String? = nil
    ) {
        self.id = id
        self.text = text
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.timingStatus = timingStatus
        self.timingModel = timingModel
    }
}

struct EditedTranscriptWord: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let outputStart: TimeInterval
    let outputEnd: TimeInterval
    let sourceStart: TimeInterval
    let sourceEnd: TimeInterval
    let timingStatus: TranscriptTimingStatus
}

struct TimedTranscript: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let projectID: UUID
    let sourceTrackID: String
    let sourceDuration: TimeInterval
    let language: String
    let recognitionModel: String
    let alignmentModel: String
    let words: [TimedTranscriptWord]

    init(
        projectID: UUID,
        sourceTrackID: String,
        sourceDuration: TimeInterval,
        language: String,
        recognitionModel: String,
        alignmentModel: String,
        words: [TimedTranscriptWord]
    ) {
        schemaVersion = 1
        self.projectID = projectID
        self.sourceTrackID = sourceTrackID
        self.sourceDuration = sourceDuration
        self.language = language
        self.recognitionModel = recognitionModel
        self.alignmentModel = alignmentModel
        self.words = words
    }

    func words(in timeline: ProjectEditTimeline) -> [EditedTranscriptWord] {
        guard timeline.trackID == sourceTrackID,
              abs(timeline.sourceDuration - sourceDuration) < 0.1 else { return [] }
        var outputStart: TimeInterval = 0
        var result: [EditedTranscriptWord] = []
        for segment in timeline.segments {
            let sourceEnd = segment.sourceStart + segment.duration
            for word in words where word.sourceStart < sourceEnd && word.sourceEnd > segment.sourceStart {
                let start = max(word.sourceStart, segment.sourceStart)
                let end = min(word.sourceEnd, sourceEnd)
                let clipped = start > word.sourceStart + 0.001 || end < word.sourceEnd - 0.001
                result.append(EditedTranscriptWord(
                    id: word.id, text: word.text,
                    outputStart: outputStart + start - segment.sourceStart,
                    outputEnd: outputStart + end - segment.sourceStart,
                    sourceStart: start, sourceEnd: end,
                    timingStatus: clipped ? .uncertain : word.timingStatus
                ))
            }
            outputStart += segment.duration
        }
        return result
    }

    func reviewWord(_ id: UUID, sourceRange: Range<TimeInterval>) throws -> TimedTranscript {
        guard sourceRange.lowerBound.isFinite, sourceRange.upperBound.isFinite,
              sourceRange.lowerBound >= 0,
              sourceRange.lowerBound < sourceRange.upperBound,
              sourceRange.upperBound <= sourceDuration,
              let index = words.firstIndex(where: { $0.id == id }) else {
            throw TimedTranscriptStoreError.invalidTranscript
        }
        var revised = words
        let original = revised[index]
        revised[index] = TimedTranscriptWord(
            id: original.id, text: original.text,
            sourceStart: sourceRange.lowerBound, sourceEnd: sourceRange.upperBound,
            timingStatus: .reviewed, timingModel: "manual"
        )
        return TimedTranscript(
            projectID: projectID, sourceTrackID: sourceTrackID,
            sourceDuration: sourceDuration, language: language,
            recognitionModel: recognitionModel, alignmentModel: alignmentModel,
            words: revised
        )
    }
}

enum TimedTranscriptStoreError: LocalizedError {
    case invalidTranscript
    case unsupportedSchema
    case projectMismatch

    var errorDescription: String? {
        switch self {
        case .invalidTranscript: "The transcript contains missing or invalid word times."
        case .unsupportedSchema: "This transcript was written by an unsupported app version."
        case .projectMismatch: "This transcript belongs to a different project."
        }
    }
}

struct TimedTranscriptStore {
    func load(in rootURL: URL, expectedProjectID: UUID) throws -> TimedTranscript? {
        let url = rootURL.appending(path: "analysis/transcript.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let transcript = try JSONDecoder().decode(TimedTranscript.self, from: Data(contentsOf: url))
        try validate(transcript, expectedProjectID: expectedProjectID)
        return transcript
    }

    func save(_ transcript: TimedTranscript, in rootURL: URL) throws {
        try validate(transcript, expectedProjectID: transcript.projectID)
        let url = rootURL.appending(path: "analysis/transcript.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(transcript).write(to: url, options: .atomic)
    }

    private func validate(_ transcript: TimedTranscript, expectedProjectID: UUID) throws {
        guard transcript.schemaVersion == 1 else { throw TimedTranscriptStoreError.unsupportedSchema }
        guard transcript.projectID == expectedProjectID else { throw TimedTranscriptStoreError.projectMismatch }
        guard transcript.sourceDuration.isFinite, transcript.sourceDuration > 0,
              !transcript.sourceTrackID.isEmpty, !transcript.language.isEmpty,
              !transcript.recognitionModel.isEmpty, !transcript.alignmentModel.isEmpty,
              Set(transcript.words.map(\.id)).count == transcript.words.count,
              transcript.words.allSatisfy({
                  !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && $0.sourceStart.isFinite && $0.sourceEnd.isFinite
                      && $0.sourceStart >= 0 && $0.sourceStart < $0.sourceEnd
                      && $0.sourceEnd <= transcript.sourceDuration + 0.05
              }) else { throw TimedTranscriptStoreError.invalidTranscript }
    }
}

enum ProjectAudioSource: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case systemAudio
    case microphone

    var id: String { rawValue }
    var label: String { self == .systemAudio ? "System Audio" : "Microphone" }
    var icon: String { self == .systemAudio ? "desktopcomputer" : "mic.fill" }
}

struct ProjectAudioStemTrackIdentity: Codable, Equatable, Sendable {
    let source: ProjectAudioSource
    let persistentTrackID: Int32
}

struct ProjectAudioStemIndex: Codable, Equatable, Sendable {
    static let filename = "scene/audio-stems.json"
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let tracks: [ProjectAudioStemTrackIdentity]

    init(tracks: [ProjectAudioStemTrackIdentity]) {
        schemaVersion = Self.currentSchemaVersion
        self.tracks = tracks
    }

    var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && !tracks.isEmpty
            && Set(tracks.map(\.source)).count == tracks.count
            && Set(tracks.map(\.persistentTrackID)).count == tracks.count
            && tracks.allSatisfy { $0.persistentTrackID != kCMPersistentTrackID_Invalid }
    }
}

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

struct ProjectAudioSourceAdjustment: Codable, Equatable, Identifiable, Sendable {
    let source: ProjectAudioSource
    var gain: Double
    var isMuted: Bool

    var id: ProjectAudioSource { source }
    var effectiveGain: Float { isMuted ? 0 : Float(gain) }
    var isUnchanged: Bool { !isMuted && abs(gain - 1) < 0.001 }
    var isPersistable: Bool { gain.isFinite && (0...1).contains(gain) }

    init(source: ProjectAudioSource, gain: Double = 1, isMuted: Bool = false) {
        self.source = source
        self.gain = min(max(gain.isFinite ? gain : 1, 0), 1)
        self.isMuted = isMuted
    }

    private enum CodingKeys: String, CodingKey { case source, gain, isMuted }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(ProjectAudioSource.self, forKey: .source)
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
    case invalidSourceAudioAdjustment
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
        case .invalidSourceAudioAdjustment:
            "A saved source audio adjustment is invalid."
        case .invalidSegmentAudioAdjustment:
            "A saved segment audio adjustment is invalid."
        }
    }
}

struct ProjectEditDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 7

    let schemaVersion: Int
    let projectID: UUID
    var updatedAt: Date
    var timelines: [ProjectEditTimeline]
    var presentation: CapturePresentationSnapshot?
    var privacyOverlays: [ProjectPrivacyOverlay]
    var sceneTimeline: StudioSceneTimeline?
    var audioAdjustment: ProjectAudioAdjustment
    var sourceAudioAdjustments: [ProjectAudioSourceAdjustment]
    var segmentAudioAdjustments: [ProjectSegmentAudioAdjustment]

    init(
        projectID: UUID,
        updatedAt: Date = Date(),
        timelines: [ProjectEditTimeline],
        presentation: CapturePresentationSnapshot? = nil,
        privacyOverlays: [ProjectPrivacyOverlay] = [],
        sceneTimeline: StudioSceneTimeline? = nil,
        audioAdjustment: ProjectAudioAdjustment = .unchanged,
        sourceAudioAdjustments: [ProjectAudioSourceAdjustment] = [],
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
        self.sourceAudioAdjustments = sourceAudioAdjustments
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

    mutating func replaceSourceAudioAdjustment(
        _ adjustment: ProjectAudioSourceAdjustment,
        updatedAt: Date = Date()
    ) {
        sourceAudioAdjustments.removeAll { $0.source == adjustment.source }
        if !adjustment.isUnchanged { sourceAudioAdjustments.append(adjustment) }
        self.updatedAt = updatedAt
    }

    func sourceAudioAdjustment(for source: ProjectAudioSource) -> ProjectAudioSourceAdjustment {
        sourceAudioAdjustments.first { $0.source == source }
            ?? ProjectAudioSourceAdjustment(source: source)
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
             audioAdjustment, sourceAudioAdjustments, segmentAudioAdjustments
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
        sourceAudioAdjustments = try container.decodeIfPresent(
            [ProjectAudioSourceAdjustment].self,
            forKey: .sourceAudioAdjustments
        ) ?? []
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
            sourceAudioAdjustments: document.sourceAudioAdjustments,
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
                || (allowsLegacy && (1...6).contains(document.schemaVersion)) else {
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
        guard document.sourceAudioAdjustments.allSatisfy({ $0.isPersistable && !$0.isUnchanged }),
              Set(document.sourceAudioAdjustments.map(\.source)).count == document.sourceAudioAdjustments.count else {
            throw ProjectEditStoreError.invalidSourceAudioAdjustment
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
