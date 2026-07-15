import Foundation

enum ProjectEditTimelineError: LocalizedError, Equatable {
    case invalidSourceDuration
    case invalidTimelineTime
    case splitAtSegmentBoundary
    case segmentNotFound
    case cannotDeleteOnlySegment

    var errorDescription: String? {
        switch self {
        case .invalidSourceDuration:
            "The source movie does not have a usable duration."
        case .invalidTimelineTime:
            "Move the playhead inside the edited movie first."
        case .splitAtSegmentBoundary:
            "The playhead is already at a cut."
        case .segmentNotFound:
            "The selected edit segment no longer exists."
        case .cannotDeleteOnlySegment:
            "At least one segment must remain in the edit."
        }
    }
}

struct ProjectEditSegment: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var sourceStart: TimeInterval
    var duration: TimeInterval
}

enum ProjectPrivacyOverlayStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case blur
    case solid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blur: "Blur"
        case .solid: "Solid"
        }
    }
}

struct ProjectPrivacyOverlay: Codable, Equatable, Identifiable, Sendable {
    static let minimumDuration: TimeInterval = 0.05
    static let minimumDimension = 0.04

    let id: UUID
    var sourceStart: TimeInterval
    var duration: TimeInterval
    var centerX: Double
    var centerY: Double
    var width: Double
    var height: Double
    var style: ProjectPrivacyOverlayStyle

    init(
        id: UUID = UUID(),
        sourceStart: TimeInterval,
        duration: TimeInterval,
        centerX: Double = 0.5,
        centerY: Double = 0.5,
        width: Double = 0.35,
        height: Double = 0.18,
        style: ProjectPrivacyOverlayStyle = .solid
    ) {
        self.id = id
        self.sourceStart = sourceStart
        self.duration = duration
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
        self.style = style
    }

    func isActive(at sourceTime: TimeInterval) -> Bool {
        sourceTime >= sourceStart && sourceTime < sourceStart + duration
    }

    func validated(sourceDuration: TimeInterval) -> ProjectPrivacyOverlay {
        var copy = validatedCanvasGeometry()
        copy.sourceStart = min(
            max(sourceStart.isFinite ? sourceStart : 0, 0),
            max(sourceDuration - Self.minimumDuration, 0)
        )
        copy.duration = min(
            max(duration.isFinite ? duration : Self.minimumDuration, Self.minimumDuration),
            max(sourceDuration - copy.sourceStart, Self.minimumDuration)
        )
        return copy
    }

    func validatedCanvasGeometry() -> ProjectPrivacyOverlay {
        var copy = self
        copy.width = min(max(width.isFinite ? width : 0.35, Self.minimumDimension), 1)
        copy.height = min(max(height.isFinite ? height : 0.18, Self.minimumDimension), 1)
        copy.centerX = min(max(centerX.isFinite ? centerX : 0.5, copy.width / 2), 1 - copy.width / 2)
        copy.centerY = min(max(centerY.isFinite ? centerY : 0.5, copy.height / 2), 1 - copy.height / 2)
        return copy
    }

    var isPersistable: Bool {
        sourceStart.isFinite
            && sourceStart >= 0
            && duration.isFinite
            && duration >= Self.minimumDuration
            && self == validatedCanvasGeometry()
    }
}

struct ProjectEditTimeline: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let trackID: String
    let sourceDuration: TimeInterval
    var segments: [ProjectEditSegment]

    var duration: TimeInterval {
        segments.reduce(0) { $0 + $1.duration }
    }

    var isIdentity: Bool {
        guard segments.count == 1, let segment = segments.first else { return false }
        return abs(segment.sourceStart) < 0.001
            && abs(segment.duration - sourceDuration) < 0.001
    }

    func sourceTime(at timelineTime: TimeInterval) -> TimeInterval? {
        guard timelineTime.isFinite,
              timelineTime >= 0,
              timelineTime <= duration,
              let location = segmentLocation(at: min(timelineTime, max(duration - 0.000_001, 0))) else {
            return nil
        }
        return location.segment.sourceStart + min(
            max(timelineTime - location.timelineStart, 0),
            location.segment.duration
        )
    }

    init(
        trackID: String,
        sourceDuration: TimeInterval,
        initialSegmentID: UUID = UUID()
    ) throws {
        guard sourceDuration.isFinite, sourceDuration > 0 else {
            throw ProjectEditTimelineError.invalidSourceDuration
        }
        schemaVersion = Self.currentSchemaVersion
        self.trackID = trackID
        self.sourceDuration = sourceDuration
        segments = [.init(id: initialSegmentID, sourceStart: 0, duration: sourceDuration)]
    }

    mutating func split(at timelineTime: TimeInterval, newSegmentID: UUID = UUID()) throws {
        guard timelineTime.isFinite, timelineTime > 0, timelineTime < duration else {
            throw ProjectEditTimelineError.invalidTimelineTime
        }
        guard let location = segmentLocation(at: timelineTime) else {
            throw ProjectEditTimelineError.invalidTimelineTime
        }
        let localTime = timelineTime - location.timelineStart
        guard localTime > 0, localTime < location.segment.duration else {
            throw ProjectEditTimelineError.splitAtSegmentBoundary
        }

        var leading = location.segment
        leading.duration = localTime
        let trailing = ProjectEditSegment(
            id: newSegmentID,
            sourceStart: location.segment.sourceStart + localTime,
            duration: location.segment.duration - localTime
        )
        segments.replaceSubrange(location.index...location.index, with: [leading, trailing])
    }

    mutating func delete(segmentID: UUID) throws {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else {
            throw ProjectEditTimelineError.segmentNotFound
        }
        guard segments.count > 1 else {
            throw ProjectEditTimelineError.cannotDeleteOnlySegment
        }
        segments.remove(at: index)
    }

    mutating func trimStart(to timelineTime: TimeInterval) throws {
        guard timelineTime.isFinite, timelineTime >= 0, timelineTime < duration else {
            throw ProjectEditTimelineError.invalidTimelineTime
        }
        guard timelineTime > 0 else { return }
        guard let location = segmentLocation(at: timelineTime) else {
            throw ProjectEditTimelineError.invalidTimelineTime
        }
        let localTime = timelineTime - location.timelineStart
        var firstRemaining = location.segment
        firstRemaining.sourceStart += localTime
        firstRemaining.duration -= localTime
        segments = [firstRemaining] + Array(segments.dropFirst(location.index + 1))
    }

    mutating func trimEnd(to timelineTime: TimeInterval) throws {
        guard timelineTime.isFinite, timelineTime > 0, timelineTime <= duration else {
            throw ProjectEditTimelineError.invalidTimelineTime
        }
        guard timelineTime < duration else { return }
        guard let location = segmentLocation(at: timelineTime) else {
            throw ProjectEditTimelineError.invalidTimelineTime
        }
        let localTime = timelineTime - location.timelineStart
        if localTime == 0 {
            segments = Array(segments.prefix(location.index))
            return
        }
        var lastRemaining = location.segment
        lastRemaining.duration = localTime
        segments = Array(segments.prefix(location.index)) + [lastRemaining]
    }

    private func segmentLocation(at timelineTime: TimeInterval) -> (
        index: Int,
        segment: ProjectEditSegment,
        timelineStart: TimeInterval
    )? {
        var timelineStart: TimeInterval = 0
        for (index, segment) in segments.enumerated() {
            let timelineEnd = timelineStart + segment.duration
            if timelineTime < timelineEnd || (timelineTime == timelineEnd && index == segments.indices.last) {
                return (index, segment, timelineStart)
            }
            timelineStart = timelineEnd
        }
        return nil
    }
}
