@preconcurrency import AVFoundation
import CoreImage
import CoreVideo
import Foundation

enum ProjectProgramExportPolicy {
    static func presetName(
        codecPolicy: RecordingCodecPolicy,
        renderSize: CGSize,
        availablePresets: [String]
    ) -> String {
        if codecPolicy == .automatic,
           renderSize.width * renderSize.height >= 3_840 * 2_160,
           availablePresets.contains(AVAssetExportPresetHEVC3840x2160) {
            return AVAssetExportPresetHEVC3840x2160
        }
        if codecPolicy == .automatic,
           availablePresets.contains(AVAssetExportPresetHEVCHighestQuality) {
            return AVAssetExportPresetHEVCHighestQuality
        }
        return AVAssetExportPresetHighestQuality
    }
}

enum ProjectProgramRenderPolicy {
    static func frameRate(requested: Int, renderSize: CGSize) -> Int {
        CaptureDefaults.frameRate(requested, for: renderSize)
    }
}

struct ProjectScreenSource: Codable, Sendable, Equatable {
    let url: URL
    let displayID: UInt32?
}

struct ProjectProgramSources: Codable, Sendable {
    let screenURL: URL
    let screenSources: [ProjectScreenSource]
    let cameraURL: URL?
    let audioURL: URL?
    let audioSourceOrder: [ProjectAudioSource]
    let audioSourceTrackIDs: [CMPersistentTrackID: ProjectAudioSource]
    let screenDisplayID: UInt32?
    let cursorTimeline: CursorSceneTimeline?
    let shortcutTimeline: SafeShortcutTimeline?
    let sceneTimeline: StudioSceneTimeline?
    let screenWasCapturedAsFixedRegion: Bool
    let cameraTimeOffset: TimeInterval
    let rendersCursor: Bool
    let frameRate: Int

    init(
        screenURL: URL,
        screenSources: [ProjectScreenSource]? = nil,
        cameraURL: URL?,
        audioURL: URL? = nil,
        audioSourceOrder: [ProjectAudioSource] = [],
        audioSourceTrackIDs: [CMPersistentTrackID: ProjectAudioSource] = [:],
        screenDisplayID: UInt32? = nil,
        cursorTimeline: CursorSceneTimeline? = nil,
        shortcutTimeline: SafeShortcutTimeline? = nil,
        sceneTimeline: StudioSceneTimeline? = nil,
        screenWasCapturedAsFixedRegion: Bool = false,
        cameraTimeOffset: TimeInterval = 0,
        rendersCursor: Bool = false,
        frameRate: Int = 30
    ) {
        self.screenURL = screenURL
        if let screenSources, !screenSources.isEmpty {
            self.screenSources = screenSources
        } else {
            self.screenSources = [ProjectScreenSource(url: screenURL, displayID: screenDisplayID)]
        }
        self.cameraURL = cameraURL
        self.audioURL = audioURL
        self.audioSourceOrder = audioSourceOrder
        self.audioSourceTrackIDs = audioSourceTrackIDs
        self.screenDisplayID = screenDisplayID
        self.cursorTimeline = cursorTimeline
        self.shortcutTimeline = shortcutTimeline
        self.sceneTimeline = sceneTimeline
        self.screenWasCapturedAsFixedRegion = screenWasCapturedAsFixedRegion
        self.cameraTimeOffset = cameraTimeOffset
        self.rendersCursor = rendersCursor
        self.frameRate = CaptureDefaults.supportedFrameRates.contains(frameRate) ? frameRate : 30
    }

    func replacingSceneTimeline(_ sceneTimeline: StudioSceneTimeline?) -> ProjectProgramSources {
        ProjectProgramSources(
            screenURL: screenURL,
            screenSources: screenSources,
            cameraURL: cameraURL,
            audioURL: audioURL,
            audioSourceOrder: audioSourceOrder,
            audioSourceTrackIDs: audioSourceTrackIDs,
            screenDisplayID: screenDisplayID,
            cursorTimeline: cursorTimeline,
            shortcutTimeline: shortcutTimeline,
            sceneTimeline: sceneTimeline,
            screenWasCapturedAsFixedRegion: screenWasCapturedAsFixedRegion,
            cameraTimeOffset: cameraTimeOffset,
            rendersCursor: rendersCursor,
            frameRate: frameRate
        )
    }
}

@MainActor
final class ProjectProgramRenderer {
    private struct CompositionResult {
        let asset: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        let audioSourceByTrackID: [CMPersistentTrackID: ProjectAudioSource]
    }

    func makePlayerItem(
        sources: ProjectProgramSources,
        timeline: ProjectEditTimeline,
        presentation: CapturePresentationSnapshot,
        privacyOverlays: [ProjectPrivacyOverlay] = [],
        audioAdjustment: ProjectAudioAdjustment = .unchanged,
        sourceAudioAdjustments: [ProjectAudioSourceAdjustment] = [],
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
            sourceAdjustments: sourceAudioAdjustments,
            sourceOrder: sources.audioSourceOrder,
            sourceByTrackID: rendered.audioSourceByTrackID,
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
        sourceAudioAdjustments: [ProjectAudioSourceAdjustment] = [],
        segmentAudioAdjustments: [ProjectSegmentAudioAdjustment] = [],
        codecPolicy: RecordingCodecPolicy = .h264,
        to destinationURL: URL,
        progress: @escaping (Double) -> Void = { _ in }
    ) async throws {
        try validateDestination(destinationURL, sources: sources)
        let rendered = try await makeComposition(
            sources: sources,
            timeline: timeline,
            presentation: presentation,
            privacyOverlays: privacyOverlays
        )
        let preferredPreset = ProjectProgramExportPolicy.presetName(
            codecPolicy: codecPolicy,
            renderSize: rendered.videoComposition.renderSize,
            availablePresets: [
                AVAssetExportPresetHighestQuality,
                AVAssetExportPresetHEVCHighestQuality,
                AVAssetExportPresetHEVC3840x2160
            ]
        )
        guard let session = AVAssetExportSession(asset: rendered.asset, presetName: preferredPreset)
            ?? AVAssetExportSession(asset: rendered.asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ProjectEditRendererError.exportUnavailable
        }
        session.videoComposition = rendered.videoComposition
        session.audioMix = ProjectAudioMixFactory.make(
            for: rendered.asset.tracks(withMediaType: .audio),
            adjustment: audioAdjustment,
            sourceAdjustments: sourceAudioAdjustments,
            sourceOrder: sources.audioSourceOrder,
            sourceByTrackID: rendered.audioSourceByTrackID,
            timeline: timeline,
            segmentAdjustments: segmentAudioAdjustments
        )
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appending(path: ".StudioRecorder-program-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        progress(0)
        let progressTask = Task { @MainActor in
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { progressTask.cancel() }
        try await session.export(to: temporaryURL, as: .mov)
        progress(1)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    private func validateDestination(_ destinationURL: URL, sources: ProjectProgramSources) throws {
        let destination = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
        let sourceURLs = sources.screenSources.map(\.url) + [sources.cameraURL, sources.audioURL].compactMap { $0 }
        for sourceURL in sourceURLs {
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
    ) async throws -> CompositionResult {
        let composition = AVMutableComposition()
        var screenTrackIDs: [UInt32: CMPersistentTrackID] = [:]
        var screenTransforms: [CMPersistentTrackID: CGAffineTransform] = [:]
        var primaryScreenTrackID: CMPersistentTrackID?
        for (index, source) in sources.screenSources.enumerated() {
            let asset = AVURLAsset(url: source.url)
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first,
                  let track = composition.addMutableTrack(
                    withMediaType: .video,
                    preferredTrackID: CMPersistentTrackID(index + 1)
                  ) else { continue }
            try await insert(timeline: timeline, from: sourceTrack, into: track)
            if let displayID = source.displayID { screenTrackIDs[displayID] = track.trackID }
            screenTransforms[track.trackID] = try await sourceTrack.load(.preferredTransform)
            if primaryScreenTrackID == nil || source.displayID == sources.screenDisplayID {
                primaryScreenTrackID = track.trackID
            }
        }
        guard let primaryScreenTrackID else {
            throw ProjectEditRendererError.noMediaTracks
        }

        let audioAsset = AVURLAsset(url: sources.audioURL ?? sources.screenURL)
        var audioSourceByTrackID: [CMPersistentTrackID: ProjectAudioSource] = [:]
        do {
            let sourceAudioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
            let hasIndexedAudioSources = !sources.audioSourceTrackIDs.isEmpty
            if hasIndexedAudioSources,
               Set(sourceAudioTracks.map(\.trackID)) != Set(sources.audioSourceTrackIDs.keys) {
                throw ProjectEditRendererError.invalidAudioStemIndex
            }
            for (index, sourceAudioTrack) in sourceAudioTracks.enumerated() {
                guard let audioTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else { continue }
                do {
                    try await insertAudio(timeline: timeline, from: sourceAudioTrack, into: audioTrack)
                    let source = hasIndexedAudioSources
                        ? sources.audioSourceTrackIDs[sourceAudioTrack.trackID]
                        : (sources.audioSourceOrder.indices.contains(index) ? sources.audioSourceOrder[index] : nil)
                    if let source {
                        audioSourceByTrackID[audioTrack.trackID] = source
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch ProjectEditRendererError.invalidAudioStemIndex {
                    throw ProjectEditRendererError.invalidAudioStemIndex
                } catch {
                    composition.removeTrack(audioTrack)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch ProjectEditRendererError.invalidAudioStemIndex {
            throw ProjectEditRendererError.invalidAudioStemIndex
        } catch {
            // Audio is optional for program playback. A healthy visual program remains useful when it is unavailable.
        }

        var cameraTrackID: CMPersistentTrackID?
        var cameraTransform = CGAffineTransform.identity
        if let cameraURL = sources.cameraURL {
            do {
                let cameraAsset = AVURLAsset(url: cameraURL)
                if let sourceCameraTrack = try await cameraAsset.loadTracks(withMediaType: .video).first,
                   let cameraTrack = composition.addMutableTrack(
                    withMediaType: .video,
                    preferredTrackID: CMPersistentTrackID(sources.screenSources.count + 1)
                   ) {
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
        let frameRate = ProjectProgramRenderPolicy.frameRate(
            requested: sources.frameRate,
            renderSize: validated.canvas.pixelSize
        )
        let instruction = ProjectProgramInstruction(
            timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: timeline.duration, preferredTimescale: 600)),
            primaryScreenTrackID: primaryScreenTrackID,
            screenTrackIDs: screenTrackIDs,
            cameraTrackID: cameraTrackID,
            presentation: validated,
            timeline: timeline,
            cursorSamples: sources.cursorTimeline?.samples ?? [],
            shortcutTimeline: sources.shortcutTimeline,
            sceneTimeline: sources.sceneTimeline,
            screenWasCapturedAsFixedRegion: sources.screenWasCapturedAsFixedRegion,
            privacyOverlays: privacyOverlays,
            rendersCursor: sources.rendersCursor,
            screenTransforms: screenTransforms,
            cameraTransform: cameraTransform,
            frameRate: frameRate
        )
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = ProjectVideoCompositor.self
        videoComposition.instructions = [instruction]
        videoComposition.renderSize = validated.canvas.pixelSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        return CompositionResult(
            asset: composition,
            videoComposition: videoComposition,
            audioSourceByTrackID: audioSourceByTrackID
        )
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

    private func insertAudio(
        timeline: ProjectEditTimeline,
        from source: AVAssetTrack,
        into destination: AVMutableCompositionTrack
    ) async throws {
        let sourceRange = try await source.load(.timeRange)
        let sourceStart = sourceRange.start.seconds
        let sourceEnd = sourceRange.end.seconds
        guard sourceStart.isFinite,
              sourceEnd.isFinite,
              sourceEnd > sourceStart else { return }
        var insertionTime = CMTime.zero

        for segment in timeline.segments {
            let segmentEnd = segment.sourceStart + segment.duration
            let overlapStart = max(segment.sourceStart, sourceStart)
            let overlapEnd = min(segmentEnd, sourceEnd)
            if overlapEnd > overlapStart {
                let destinationStart = insertionTime + CMTime(
                    seconds: overlapStart - segment.sourceStart,
                    preferredTimescale: 600
                )
                let range = CMTimeRange(
                    start: CMTime(seconds: overlapStart, preferredTimescale: 600),
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
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let primaryScreenTrackID: CMPersistentTrackID
    let screenTrackIDs: [UInt32: CMPersistentTrackID]
    let cameraTrackID: CMPersistentTrackID?
    let presentation: CapturePresentationSnapshot
    let timeline: ProjectEditTimeline
    let cursorTimeline: CursorSceneTimeline?
    let shortcutTimeline: SafeShortcutTimeline?
    let sceneTimeline: StudioSceneTimeline?
    let screenWasCapturedAsFixedRegion: Bool
    let privacyOverlays: [ProjectPrivacyOverlay]
    let rendersCursor: Bool
    let screenTransforms: [CMPersistentTrackID: CGAffineTransform]
    let cameraTransform: CGAffineTransform
    let outputDuration: TimeInterval
    let frameRate: Int
    let cinematicViewportFrames: [ScreenFramingSnapshot?]

    init(
        timeRange: CMTimeRange,
        primaryScreenTrackID: CMPersistentTrackID,
        screenTrackIDs: [UInt32: CMPersistentTrackID],
        cameraTrackID: CMPersistentTrackID?,
        presentation: CapturePresentationSnapshot,
        timeline: ProjectEditTimeline,
        cursorSamples: [CursorSceneSample],
        shortcutTimeline: SafeShortcutTimeline?,
        sceneTimeline: StudioSceneTimeline?,
        screenWasCapturedAsFixedRegion: Bool,
        privacyOverlays: [ProjectPrivacyOverlay],
        rendersCursor: Bool,
        screenTransforms: [CMPersistentTrackID: CGAffineTransform],
        cameraTransform: CGAffineTransform,
        frameRate: Int
    ) {
        let cursorTimeline = cursorSamples.isEmpty ? nil : CursorSceneTimeline(samples: cursorSamples)
        let outputDuration = timeRange.duration.seconds
        self.timeRange = timeRange
        self.primaryScreenTrackID = primaryScreenTrackID
        self.screenTrackIDs = screenTrackIDs
        self.cameraTrackID = cameraTrackID
        self.presentation = presentation
        self.timeline = timeline
        self.cursorTimeline = cursorTimeline
        self.shortcutTimeline = shortcutTimeline
        self.sceneTimeline = sceneTimeline
        self.screenWasCapturedAsFixedRegion = screenWasCapturedAsFixedRegion
        self.privacyOverlays = privacyOverlays
        self.rendersCursor = rendersCursor
        self.screenTransforms = screenTransforms
        self.cameraTransform = cameraTransform
        self.outputDuration = outputDuration
        self.frameRate = frameRate
        cinematicViewportFrames = Self.makeCinematicViewportFrames(
            outputDuration: outputDuration,
            frameRate: frameRate,
            presentation: presentation,
            timeline: timeline,
            cursorTimeline: cursorTimeline,
            sceneTimeline: sceneTimeline
        )
        requiredSourceTrackIDs = (Array(Set(screenTrackIDs.values).union([primaryScreenTrackID]))
            + (cameraTrackID.map { [$0] } ?? [])).map {
            NSNumber(value: $0)
        }
    }

    func screenTrackID(at compositionTime: CMTime) -> CMPersistentTrackID {
        guard let sourceTime = timeline.sourceTime(at: compositionTime.seconds) else {
            return primaryScreenTrackID
        }
        if let displayID = sceneTimeline?.displayID(at: sourceTime),
           let trackID = screenTrackIDs[displayID] {
            return trackID
        }
        if presentation(at: compositionTime).framing.mode == .followCursor,
           let displayID = cursorTimeline?.sample(at: sourceTime, for: nil)?.displayID,
           let trackID = screenTrackIDs[displayID] {
            return trackID
        }
        return primaryScreenTrackID
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
            return cinematicViewportFrame(at: compositionTime.seconds) ?? activePresentation.framing
        }
    }

    private func cinematicViewportFrame(at compositionTime: TimeInterval) -> ScreenFramingSnapshot? {
        guard !cinematicViewportFrames.isEmpty else { return nil }
        let frame = Int(floor(max(compositionTime, 0) * Double(frameRate) + 0.000_001))
        return cinematicViewportFrames[min(frame, cinematicViewportFrames.count - 1)]
    }

    private static func makeCinematicViewportFrames(
        outputDuration: TimeInterval,
        frameRate: Int,
        presentation: CapturePresentationSnapshot,
        timeline: ProjectEditTimeline,
        cursorTimeline: CursorSceneTimeline?,
        sceneTimeline: StudioSceneTimeline?
    ) -> [ScreenFramingSnapshot?] {
        let frameDuration = 1 / Double(frameRate)
        let frameCount = max(Int(ceil(outputDuration * Double(frameRate))) + 1, 1)
        var frames: [ScreenFramingSnapshot?] = []
        frames.reserveCapacity(frameCount)
        var motion = CursorFollowMotion()
        var previousCompositionTime: TimeInterval?
        var previousSourceTime: TimeInterval?
        var previousDisplayID: UInt32?
        var wasFollowing = false

        for frameIndex in 0..<frameCount {
            let compositionTime = min(Double(frameIndex) * frameDuration, outputDuration)
            guard let sourceTime = timeline.sourceTime(at: compositionTime) else {
                frames.append(nil)
                motion.reset()
                wasFollowing = false
                continue
            }
            let activePresentation = sceneTimeline?.presentation(at: sourceTime) ?? presentation
            guard activePresentation.framing.mode == .followCursor,
                  let sample = cursorTimeline?.sample(at: sourceTime, for: nil) else {
                frames.append(nil)
                motion.reset()
                previousCompositionTime = compositionTime
                previousSourceTime = sourceTime
                previousDisplayID = nil
                wasFollowing = false
                continue
            }

            let displayID = sceneTimeline?.displayID(at: sourceTime) ?? sample.displayID
            let sourceIsDiscontinuous = if let previousCompositionTime, let previousSourceTime {
                abs((sourceTime - previousSourceTime) - (compositionTime - previousCompositionTime))
                    > frameDuration / 2
            } else {
                false
            }
            if !wasFollowing || sourceIsDiscontinuous || previousDisplayID != displayID {
                motion.reset()
            }
            let center = motion.update(
                target: CGPoint(x: sample.normalizedX, y: sample.normalizedY),
                at: compositionTime
            )
            frames.append(ScreenFramingSnapshot(
                mode: .fixedRegion,
                centerX: center.x,
                centerY: center.y,
                scale: activePresentation.framing.scale
            ).validated())
            previousCompositionTime = compositionTime
            previousSourceTime = sourceTime
            previousDisplayID = displayID
            wasFollowing = true
        }
        return frames
    }

    func presentation(at compositionTime: CMTime) -> CapturePresentationSnapshot {
        let activePresentation: CapturePresentationSnapshot
        if let sourceTime = timeline.sourceTime(at: compositionTime.seconds),
           let sceneTimeline {
            activePresentation = sceneTimeline.presentation(at: sourceTime)
        } else {
            activePresentation = presentation
        }
        return StudioSceneInterpolator.applyingOpacity(
            StudioRecordingBoundaryFade.opacity(
                at: compositionTime.seconds,
                outputDuration: outputDuration
            ),
            to: activePresentation
        )
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

        let screenTrackID = instruction.screenTrackID(at: request.compositionTime)
        let screen = request.sourceFrame(byTrackID: screenTrackID).map(CIImage.init(cvPixelBuffer:))
        let camera = instruction.cameraTrackID
            .flatMap { request.sourceFrame(byTrackID: $0) }
            .map(CIImage.init(cvPixelBuffer:))
        let presentation = instruction.presentation(at: request.compositionTime)
        compositor.render(
            screen: screen,
            camera: camera,
            screenTransform: instruction.screenTransforms[screenTrackID] ?? .identity,
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
