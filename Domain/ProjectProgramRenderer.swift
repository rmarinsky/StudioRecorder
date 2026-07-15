@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation

struct ProjectProgramSources: Sendable {
    let screenURL: URL
    let cameraURL: URL?
    let audioURL: URL?

    init(screenURL: URL, cameraURL: URL?, audioURL: URL? = nil) {
        self.screenURL = screenURL
        self.cameraURL = cameraURL
        self.audioURL = audioURL
    }
}

@MainActor
final class ProjectProgramRenderer {
    func makePlayerItem(
        sources: ProjectProgramSources,
        timeline: ProjectEditTimeline,
        presentation: CapturePresentationSnapshot
    ) async throws -> AVPlayerItem {
        let rendered = try await makeComposition(
            sources: sources,
            timeline: timeline,
            presentation: presentation
        )
        let item = AVPlayerItem(asset: rendered.asset)
        item.videoComposition = rendered.videoComposition
        return item
    }

    func exportMovie(
        sources: ProjectProgramSources,
        timeline: ProjectEditTimeline,
        presentation: CapturePresentationSnapshot,
        to destinationURL: URL
    ) async throws {
        try validateDestination(destinationURL, sources: sources)
        let rendered = try await makeComposition(
            sources: sources,
            timeline: timeline,
            presentation: presentation
        )
        guard let session = AVAssetExportSession(asset: rendered.asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ProjectEditRendererError.exportUnavailable
        }
        session.videoComposition = rendered.videoComposition
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
        presentation: CapturePresentationSnapshot
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
                        try await insert(
                            timeline: timeline,
                            from: sourceCameraTrack,
                            into: cameraTrack,
                            allowsShortSource: true
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
        into destination: AVMutableCompositionTrack,
        allowsShortSource: Bool = false
    ) async throws {
        let sourceDuration = allowsShortSource ? try await source.load(.timeRange).duration.seconds : nil
        var insertionTime = CMTime.zero
        for segment in timeline.segments {
            var duration = segment.duration
            if let sourceDuration {
                let available = sourceDuration - segment.sourceStart
                duration = min(duration, max(available, 0))
            }
            guard duration > 0 else { continue }
            let range = CMTimeRange(
                start: CMTime(seconds: segment.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: duration, preferredTimescale: 600)
            )
            try destination.insertTimeRange(range, of: source, at: insertionTime)
            insertionTime = insertionTime + range.duration
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
    let screenTransform: CGAffineTransform
    let cameraTransform: CGAffineTransform

    init(
        timeRange: CMTimeRange,
        screenTrackID: CMPersistentTrackID,
        cameraTrackID: CMPersistentTrackID?,
        presentation: CapturePresentationSnapshot,
        screenTransform: CGAffineTransform,
        cameraTransform: CGAffineTransform
    ) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.presentation = presentation
        self.screenTransform = screenTransform
        self.cameraTransform = cameraTransform
        requiredSourceTrackIDs = ([screenTrackID] + (cameraTrackID.map { [$0] } ?? [])).map {
            NSNumber(value: $0)
        }
    }
}

private final class ProjectVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])

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

        let canvas = CGRect(origin: .zero, size: instruction.presentation.canvas.pixelSize)
        var result = CIImage(color: CIColor(red: 0.04, green: 0.04, blue: 0.04)).cropped(to: canvas)
        if instruction.presentation.screen.isVisible,
           let buffer = request.sourceFrame(byTrackID: instruction.screenTrackID) {
            result = compose(
                CIImage(cvPixelBuffer: buffer),
                transform: instruction.screenTransform,
                placement: instruction.presentation.screen,
                canvas: canvas,
                over: result
            )
        }
        if instruction.presentation.camera.isVisible,
           let cameraTrackID = instruction.cameraTrackID,
           let buffer = request.sourceFrame(byTrackID: cameraTrackID) {
            result = compose(
                CIImage(cvPixelBuffer: buffer),
                transform: instruction.cameraTransform,
                placement: instruction.presentation.camera,
                canvas: canvas,
                over: result
            )
        }
        context.render(result, to: output, bounds: canvas, colorSpace: CGColorSpaceCreateDeviceRGB())
        request.finish(withComposedVideoFrame: output)
    }

    private func compose(
        _ source: CIImage,
        transform: CGAffineTransform,
        placement: SourcePlacementSnapshot,
        canvas: CGRect,
        over background: CIImage
    ) -> CIImage {
        var oriented = source.transformed(by: transform)
        oriented = oriented.transformed(by: CGAffineTransform(
            translationX: -oriented.extent.minX,
            y: -oriented.extent.minY
        ))
        let target = CGRect(
            x: canvas.width * placement.centerX - canvas.width * placement.width / 2,
            y: canvas.height * (1 - placement.centerY) - canvas.height * placement.height / 2,
            width: canvas.width * placement.width,
            height: canvas.height * placement.height
        )
        let scale = max(target.width / oriented.extent.width, target.height / oriented.extent.height)
        var foreground = oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        foreground = foreground.transformed(by: CGAffineTransform(
            translationX: target.midX - foreground.extent.midX,
            y: target.midY - foreground.extent.midY
        )).cropped(to: target)
        if placement.isMirrored {
            foreground = foreground.transformed(by: CGAffineTransform(
                translationX: target.midX,
                y: 0
            ).scaledBy(x: -1, y: 1).translatedBy(x: -target.midX, y: 0))
        }
        guard placement.shape != .rectangle else { return foreground.composited(over: background) }

        let mask: CIImage?
        if placement.shape == .circle {
            let ellipse = CIFilter.radialGradient()
            ellipse.center = .zero
            ellipse.radius0 = 0.499
            ellipse.radius1 = 0.501
            ellipse.color0 = .white
            ellipse.color1 = .clear
            mask = ellipse.outputImage?
                .transformed(by: CGAffineTransform(scaleX: target.width, y: target.height))
                .transformed(by: CGAffineTransform(translationX: target.midX, y: target.midY))
                .cropped(to: target)
        } else {
            let roundedRectangle = CIFilter.roundedRectangleGenerator()
            roundedRectangle.extent = target
            roundedRectangle.radius = Float(max(4, placement.cornerRadius * min(target.width, target.height)))
            roundedRectangle.color = .white
            mask = roundedRectangle.outputImage
        }
        guard let mask else { return foreground.composited(over: background) }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = foreground
        blend.backgroundImage = background
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: canvas) ?? foreground.composited(over: background)
    }
}
