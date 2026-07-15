@preconcurrency import AVFoundation
import Foundation

enum ProjectEditRendererError: LocalizedError, Equatable {
    case unreadableSource
    case noMediaTracks
    case exportUnavailable
    case unsafeDestination

    var errorDescription: String? {
        switch self {
        case .unreadableSource:
            "The selected raw movie could not be read for editing."
        case .noMediaTracks:
            "The selected raw movie has no editable media tracks."
        case .exportUnavailable:
            "A compatible movie export is unavailable for this edit."
        case .unsafeDestination:
            "Choose a destination outside the project's immutable raw tracks."
        }
    }
}

@MainActor
final class ProjectEditRenderer {
    func makePlayerItem(
        from sourceURL: URL,
        timeline: ProjectEditTimeline,
        audioAdjustment: ProjectAudioAdjustment = .unchanged,
        segmentAudioAdjustments: [ProjectSegmentAudioAdjustment] = []
    ) async throws -> AVPlayerItem {
        let composition = try await makeComposition(from: sourceURL, timeline: timeline)
        let item = AVPlayerItem(asset: composition)
        item.audioMix = ProjectAudioMixFactory.make(
            for: composition.tracks(withMediaType: .audio),
            adjustment: audioAdjustment,
            timeline: timeline,
            segmentAdjustments: segmentAudioAdjustments
        )
        return item
    }

    func exportMovie(
        from sourceURL: URL,
        timeline: ProjectEditTimeline,
        audioAdjustment: ProjectAudioAdjustment = .unchanged,
        segmentAudioAdjustments: [ProjectSegmentAudioAdjustment] = [],
        to destinationURL: URL
    ) async throws {
        try validateDestination(destinationURL, for: sourceURL)
        let composition = try await makeComposition(from: sourceURL, timeline: timeline)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ProjectEditRendererError.exportUnavailable
        }
        session.audioMix = ProjectAudioMixFactory.make(
            for: composition.tracks(withMediaType: .audio),
            adjustment: audioAdjustment,
            timeline: timeline,
            segmentAdjustments: segmentAudioAdjustments
        )
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appending(path: ".StudioRecorder-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        try await session.export(to: temporaryURL, as: .mov)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    private func validateDestination(_ destinationURL: URL, for sourceURL: URL) throws {
        let source = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let destination = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
        guard source != destination else {
            throw ProjectEditRendererError.unsafeDestination
        }

        let sourceDirectory = source.deletingLastPathComponent()
        if sourceDirectory.lastPathComponent == "raw-tracks",
           destination.path.hasPrefix(sourceDirectory.path + "/") {
            throw ProjectEditRendererError.unsafeDestination
        }
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

enum ProjectAudioMixFactory {
    static func make(
        for tracks: [AVAssetTrack],
        adjustment: ProjectAudioAdjustment,
        timeline: ProjectEditTimeline? = nil,
        segmentAdjustments: [ProjectSegmentAudioAdjustment] = []
    ) -> AVAudioMix? {
        guard !tracks.isEmpty,
              !adjustment.isUnchanged || segmentAdjustments.contains(where: { !$0.isUnchanged }) else { return nil }
        let segmentAdjustments = segmentAdjustments.reduce(into: [UUID: ProjectSegmentAudioAdjustment]()) {
            $0[$1.segmentID] = $1
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            guard let timeline else {
                parameters.setVolume(adjustment.effectiveGain, at: .zero)
                return parameters
            }
            var outputTime = CMTime.zero
            for segment in timeline.segments {
                let segmentGain = segmentAdjustments[segment.id]?.effectiveGain ?? 1
                parameters.setVolume(adjustment.effectiveGain * segmentGain, at: outputTime)
                outputTime = outputTime + CMTime(seconds: segment.duration, preferredTimescale: 600)
            }
            return parameters
        }
        return mix
    }
}
