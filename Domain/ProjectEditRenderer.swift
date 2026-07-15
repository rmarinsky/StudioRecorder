@preconcurrency import AVFoundation
import Foundation

enum ProjectEditRendererError: LocalizedError, Equatable {
    case unreadableSource
    case noMediaTracks
    case exportUnavailable

    var errorDescription: String? {
        switch self {
        case .unreadableSource:
            "The selected raw movie could not be read for editing."
        case .noMediaTracks:
            "The selected raw movie has no editable media tracks."
        case .exportUnavailable:
            "A compatible movie export is unavailable for this edit."
        }
    }
}

@MainActor
final class ProjectEditRenderer {
    func makePlayerItem(from sourceURL: URL, timeline: ProjectEditTimeline) async throws -> AVPlayerItem {
        AVPlayerItem(asset: try await makeComposition(from: sourceURL, timeline: timeline))
    }

    func exportMovie(from sourceURL: URL, timeline: ProjectEditTimeline, to destinationURL: URL) async throws {
        let composition = try await makeComposition(from: sourceURL, timeline: timeline)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ProjectEditRendererError.exportUnavailable
        }
        try? FileManager.default.removeItem(at: destinationURL)
        try await session.export(to: destinationURL, as: .mov)
    }

    private func makeComposition(from sourceURL: URL, timeline: ProjectEditTimeline) async throws -> AVMutableComposition {
        let source = AVURLAsset(url: sourceURL)
        guard (try? await source.load(.isReadable)) == true else {
            throw ProjectEditRendererError.unreadableSource
        }

        let composition = AVMutableComposition()
        var insertedTrackCount = 0
        for mediaType in [AVMediaType.video, .audio] {
            let sourceTracks = try await source.loadTracks(withMediaType: mediaType)
            for sourceTrack in sourceTracks {
                guard let destinationTrack = composition.addMutableTrack(
                    withMediaType: mediaType,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else {
                    continue
                }
                var insertionTime = CMTime.zero
                for segment in timeline.segments {
                    let range = CMTimeRange(
                        start: CMTime(seconds: segment.sourceStart, preferredTimescale: 600),
                        duration: CMTime(seconds: segment.duration, preferredTimescale: 600)
                    )
                    try destinationTrack.insertTimeRange(range, of: sourceTrack, at: insertionTime)
                    insertionTime = insertionTime + range.duration
                }
                if mediaType == .video {
                    destinationTrack.preferredTransform = try await sourceTrack.load(.preferredTransform)
                }
                insertedTrackCount += 1
            }
        }
        guard insertedTrackCount > 0 else {
            throw ProjectEditRendererError.noMediaTracks
        }
        return composition
    }
}
