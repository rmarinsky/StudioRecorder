@preconcurrency import AVFoundation
import CoreImage
import CoreVideo
import Foundation

struct ProjectProgramSources: Sendable {
    let screenURL: URL
    let cameraURL: URL?
    let audioURL: URL?
    let screenDisplayID: UInt32?
    let cursorTimeline: CursorSceneTimeline?
    let shortcutTimeline: SafeShortcutTimeline?
    let sceneTimeline: StudioSceneTimeline?
    let screenWasCapturedAsFixedRegion: Bool
    let cameraTimeOffset: TimeInterval
    let rendersCursor: Bool

    init(
        screenURL: URL,
        cameraURL: URL?,
        audioURL: URL? = nil,
        screenDisplayID: UInt32? = nil,
        cursorTimeline: CursorSceneTimeline? = nil,
        shortcutTimeline: SafeShortcutTimeline? = nil,
        sceneTimeline: StudioSceneTimeline? = nil,
        screenWasCapturedAsFixedRegion: Bool = false,
        cameraTimeOffset: TimeInterval = 0,
        rendersCursor: Bool = false
    ) {
        self.screenURL = screenURL
        self.cameraURL = cameraURL
        self.audioURL = audioURL
        self.screenDisplayID = screenDisplayID
        self.cursorTimeline = cursorTimeline
        self.shortcutTimeline = shortcutTimeline
        self.sceneTimeline = sceneTimeline
        self.screenWasCapturedAsFixedRegion = screenWasCapturedAsFixedRegion
        self.cameraTimeOffset = cameraTimeOffset
        self.rendersCursor = rendersCursor
    }

    func replacingSceneTimeline(_ sceneTimeline: StudioSceneTimeline?) -> ProjectProgramSources {
        ProjectProgramSources(
            screenURL: screenURL,
            cameraURL: cameraURL,
            audioURL: audioURL,
            screenDisplayID: screenDisplayID,
            cursorTimeline: cursorTimeline,
            shortcutTimeline: shortcutTimeline,
            sceneTimeline: sceneTimeline,
            screenWasCapturedAsFixedRegion: screenWasCapturedAsFixedRegion,
            cameraTimeOffset: cameraTimeOffset,
            rendersCursor: rendersCursor
        )
    }
}

@MainActor
final class ProjectProgramRenderer {
    func makePlayerItem(
        sources: ProjectProgramSources,
        timeline: ProjectEditTimeline,
        presentation: CapturePresentationSnapshot,
        privacyOverlays: [ProjectPrivacyOverlay] = [],
        audioAdjustment: ProjectAudioAdjustment = .unchanged,
        segmentAudioAdjustments: [ProjectSegmentAudioAdjustment] = []
    ) async throws -> AVPlayerItem {
        let rendered = try await makeComposition(
            sources: sources,
            timeline: timeline,
            presentation: presentation,
            privacyOverlays: privacyOverlays
        )
        let item = AVPlayerItem(asset: rendered.asset)
        item.videoComposition = rendered.videoComposition
        item.audioMix = ProjectAudioMixFactory.make(
            for: rendered.asset.tracks(withMediaType: .audio),
            adjustment: audioAdjustment,
            timeline: timeline,
            segmentAdjustments: segmentAudioAdjustments
        )
        return item
    }

    func exportMovie(
        sources: ProjectProgramSources,
        timeline: ProjectEditTimeline,
        presentation: CapturePresentationSnapshot,
        privacyOverlays: [ProjectPrivacyOverlay] = [],
        audioAdjustment: ProjectAudioAdjustment = .unchanged,
        segmentAudioAdjustments: [ProjectSegmentAudioAdjustment] = [],
        to destinationURL: URL
    ) async throws {
        try validateDestination(destinationURL, sources: sources)
        let rendered = try await makeComposition(
            sources: sources,
            timeline: timeline,
            presentation: presentation,
            privacyOverlays: privacyOverlays
        )
        guard let session = AVAssetExportSession(asset: rendered.asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ProjectEditRendererError.exportUnavailable
        }
        session.videoComposition = rendered.videoComposition
        session.audioMix = ProjectAudioMixFactory.make(
            for: rendered.asset.tracks(withMediaType: .audio),
            adjustment: audioAdjustment,
            timeline: timeline,
            segmentAdjustments: segmentAudioAdjustments
        )
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appending(path: ".StudioRecorder-program-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try await session.export(to: temporaryURL, as: .mov)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    private func validateDestination(_ destinationURL: URL, sources: ProjectProgramSources) throws {
        let destination = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
        for sourceURL in [sources.screenURL, sources.cameraURL].compactMap({ $0 }) {
            let source = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
            guard destination != source else { throw ProjectEditRendererError.unsafeDestination }
            let sourceDirectory = source.deletingLastPathComponent()
            if sourceDirectory.lastPathComponent == "raw-tracks",
               destination.path.hasPrefix(sourceDirectory.path + "/") {
                throw ProjectEditRendererError.unsafeDestination
            }
        }
    }

    private func makeComposition(
        sources: ProjectProgramSources,
        timeline: ProjectEditTimeline,
        presentation: CapturePresentationSnapshot,
        privacyOverlays: [ProjectPrivacyOverlay]
    ) async throws -> (asset: AVMutableComposition, videoComposition: AVMutableVideoComposition) {
        let composition = AVMutableComposition()
        let screenAsset = AVURLAsset(url: sources.screenURL)
        guard let sourceScreenTrack = try await screenAsset.loadTracks(withMediaType: .video).first,
              let screenTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 1) else {
            throw ProjectEditRendererError.noMediaTracks
        }
        try await insert(timeline: timeline, from: sourceScreenTrack, into: screenTrack)

        let audioAsset = sources.audioURL.map(AVURLAsset.init(url:)) ?? screenAsset
        do {
            for sourceAudioTrack in try await audioAsset.loadTracks(withMediaType: .audio) {
                guard let audioTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else { continue }
                do {
                    try await insert(timeline: timeline, from: sourceAudioTrack, into: audioTrack)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    composition.removeTrack(audioTrack)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Audio is optional for program playback. A healthy visual program remains useful when it is unavailable.
        }

        var cameraTrackID: CMPersistentTrackID?
        var cameraTransform = CGAffineTransform.identity
        if let cameraURL = sources.cameraURL {
            do {
                let cameraAsset = AVURLAsset(url: cameraURL)
                if let sourceCameraTrack = try await cameraAsset.loadTracks(withMediaType: .video).first,
                   let cameraTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 2) {
                    do {
                        try await insertCamera(
                            timeline: timeline,
                            from: sourceCameraTrack,
                            into: cameraTrack,
                            screenTimeOffset: sources.cameraTimeOffset
                        )
                        cameraTrackID = cameraTrack.trackID
                        cameraTransform = try await sourceCameraTrack.load(.preferredTransform)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        composition.removeTrack(cameraTrack)
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The camera is an optional program layer. A damaged or missing camera must not hide a healthy screen.
            }
        }

        let validated = presentation.validated()
        let instruction = ProjectProgramInstruction(
            timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: timeline.duration, preferredTimescale: 600)),
            screenTrackID: screenTrack.trackID,
            cameraTrackID: cameraTrackID,
            presentation: validated,
            timeline: timeline,
            cursorSamples: sources.cursorTimeline?.samples.filter {
                sources.screenDisplayID == nil || $0.displayID == sources.screenDisplayID
            } ?? [],
            shortcutTimeline: sources.shortcutTimeline,
            sceneTimeline: sources.sceneTimeline,
            screenWasCapturedAsFixedRegion: sources.screenWasCapturedAsFixedRegion,
            privacyOverlays: privacyOverlays,
            rendersCursor: sources.rendersCursor,
            screenTransform: try await sourceScreenTrack.load(.preferredTransform),
            cameraTransform: cameraTransform
        )
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = ProjectVideoCompositor.self
        videoComposition.instructions = [instruction]
        videoComposition.renderSize = validated.canvas.pixelSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        return (composition, videoComposition)
    }

    private func insert(
        timeline: ProjectEditTimeline,
        from source: AVAssetTrack,
        into destination: AVMutableCompositionTrack
    ) async throws {
        var insertionTime = CMTime.zero
        for segment in timeline.segments {
            let range = CMTimeRange(
                start: CMTime(seconds: segment.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: segment.duration, preferredTimescale: 600)
            )
            try destination.insertTimeRange(range, of: source, at: insertionTime)
            insertionTime = insertionTime + range.duration
        }
    }

    private func insertCamera(
        timeline: ProjectEditTimeline,
        from source: AVAssetTrack,
        into destination: AVMutableCompositionTrack,
        screenTimeOffset: TimeInterval
    ) async throws {
        let cameraDuration = try await source.load(.timeRange).duration.seconds
        guard cameraDuration.isFinite, cameraDuration > 0 else { return }
        let cameraStart = screenTimeOffset
        let cameraEnd = cameraStart + cameraDuration
        var insertionTime = CMTime.zero

        for segment in timeline.segments {
            let segmentEnd = segment.sourceStart + segment.duration
            let overlapStart = max(segment.sourceStart, cameraStart)
            let overlapEnd = min(segmentEnd, cameraEnd)
            if overlapEnd > overlapStart {
                let sourceStart = overlapStart - cameraStart
                let destinationStart = insertionTime + CMTime(
                    seconds: overlapStart - segment.sourceStart,
                    preferredTimescale: 600
                )
                let range = CMTimeRange(
                    start: CMTime(seconds: sourceStart, preferredTimescale: 600),
                    duration: CMTime(seconds: overlapEnd - overlapStart, preferredTimescale: 600)
                )
                try destination.insertTimeRange(range, of: source, at: destinationStart)
            }
            insertionTime = insertionTime + CMTime(seconds: segment.duration, preferredTimescale: 600)
        }
    }
}

private final class ProjectProgramInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = false
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID?
    let presentation: CapturePresentationSnapshot
    let timeline: ProjectEditTimeline
    let cursorTimeline: CursorSceneTimeline?
    let shortcutTimeline: SafeShortcutTimeline?
    let sceneTimeline: StudioSceneTimeline?
    let screenWasCapturedAsFixedRegion: Bool
    let privacyOverlays: [ProjectPrivacyOverlay]
    let rendersCursor: Bool
    let screenTransform: CGAffineTransform
    let cameraTransform: CGAffineTransform

    init(
        timeRange: CMTimeRange,
        screenTrackID: CMPersistentTrackID,
        cameraTrackID: CMPersistentTrackID?,
        presentation: CapturePresentationSnapshot,
        timeline: ProjectEditTimeline,
        cursorSamples: [CursorSceneSample],
        shortcutTimeline: SafeShortcutTimeline?,
        sceneTimeline: StudioSceneTimeline?,
        screenWasCapturedAsFixedRegion: Bool,
        privacyOverlays: [ProjectPrivacyOverlay],
        rendersCursor: Bool,
        screenTransform: CGAffineTransform,
        cameraTransform: CGAffineTransform
    ) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.presentation = presentation
        self.timeline = timeline
        cursorTimeline = cursorSamples.isEmpty ? nil : CursorSceneTimeline(samples: cursorSamples)
        self.shortcutTimeline = shortcutTimeline
        self.sceneTimeline = sceneTimeline
        self.screenWasCapturedAsFixedRegion = screenWasCapturedAsFixedRegion
        self.privacyOverlays = privacyOverlays
        self.rendersCursor = rendersCursor
        self.screenTransform = screenTransform
        self.cameraTransform = cameraTransform
        requiredSourceTrackIDs = ([screenTrackID] + (cameraTrackID.map { [$0] } ?? [])).map {
            NSNumber(value: $0)
        }
    }

    func screenFraming(at compositionTime: CMTime) -> ScreenFramingSnapshot? {
        let activePresentation = presentation(at: compositionTime)
        // Fixed-region ScreenCaptureKit tracks are already cropped at capture time.
        // Live switching rejects region changes for those tracks, so cropping again
        // here would incorrectly zoom the saved program twice.
        if screenWasCapturedAsFixedRegion {
            return nil
        }
        switch activePresentation.framing.mode {
        case .fullDisplay:
            return nil
        case .fixedRegion:
            return activePresentation.framing
        case .followCursor:
            guard let sourceTime = timeline.sourceTime(at: compositionTime.seconds),
                  let sample = cursorTimeline?.sample(at: sourceTime, for: nil) else {
                return activePresentation.framing
            }
            return ScreenFramingSnapshot(
                mode: .fixedRegion,
                centerX: sample.normalizedX,
                centerY: sample.normalizedY,
                scale: activePresentation.framing.scale
            ).validated()
        }
    }

    func presentation(at compositionTime: CMTime) -> CapturePresentationSnapshot {
        guard let sourceTime = timeline.sourceTime(at: compositionTime.seconds),
              let sceneTimeline else { return presentation }
        return sceneTimeline.presentation(at: sourceTime)
    }

    func cursorState(at compositionTime: CMTime) -> ProgramCursorState? {
        guard rendersCursor,
              let sourceTime = timeline.sourceTime(at: compositionTime.seconds),
              let sample = cursorTimeline?.sample(at: sourceTime, for: nil) else {
            return nil
        }
        return ProgramCursorState(
            normalizedX: sample.normalizedX,
            normalizedY: sample.normalizedY,
            isPrimaryButtonDown: sample.isPrimaryButtonDown
        )
    }

    func activePrivacyOverlays(at compositionTime: CMTime) -> [ProjectPrivacyOverlay] {
        guard let sourceTime = timeline.sourceTime(at: compositionTime.seconds) else { return [] }
        return privacyOverlays.filter { $0.isActive(at: sourceTime) }
    }

    func activeShortcutLabel(at compositionTime: CMTime) -> String? {
        guard presentation(at: compositionTime).cursor.resolvedShowsShortcutKeys,
              let sourceTime = timeline.sourceTime(at: compositionTime.seconds) else { return nil }
        return shortcutTimeline?.activeLabel(at: sourceTime)
    }
}

private final class ProjectVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let compositor = ProgramFrameCompositor(personQuality: .export)

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? ProjectProgramInstruction,
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: ProjectEditRendererError.noMediaTracks)
            return
        }

        let screen = request.sourceFrame(byTrackID: instruction.screenTrackID).map(CIImage.init(cvPixelBuffer:))
        let camera = instruction.cameraTrackID
            .flatMap { request.sourceFrame(byTrackID: $0) }
            .map(CIImage.init(cvPixelBuffer:))
        let presentation = instruction.presentation(at: request.compositionTime)
        compositor.render(
            screen: screen,
            camera: camera,
            screenTransform: instruction.screenTransform,
            cameraTransform: instruction.cameraTransform,
            presentation: presentation,
            screenFraming: instruction.screenFraming(at: request.compositionTime),
            cursor: instruction.cursorState(at: request.compositionTime),
            shortcutLabel: instruction.activeShortcutLabel(at: request.compositionTime),
            privacyOverlays: instruction.activePrivacyOverlays(at: request.compositionTime),
            to: output
        )
        request.finish(withComposedVideoFrame: output)
    }
}
