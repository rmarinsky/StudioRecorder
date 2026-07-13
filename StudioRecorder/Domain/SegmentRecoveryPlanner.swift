import Foundation

struct RecordingSegment: Codable, Equatable, Identifiable {
    let id: String
    let duration: TimeInterval
    let isFinalized: Bool
}

struct SegmentRecoveryPlan: Equatable {
    let recovered: [RecordingSegment]
    let discarded: [RecordingSegment]

    var recoveredDuration: TimeInterval {
        recovered.reduce(0) { $0 + $1.duration }
    }
}

enum SegmentRecoveryPlanner {
    static func recover(_ segments: [RecordingSegment]) -> SegmentRecoveryPlan {
        SegmentRecoveryPlan(
            recovered: segments.filter(\.isFinalized),
            discarded: segments.filter { !$0.isFinalized }
        )
    }
}
