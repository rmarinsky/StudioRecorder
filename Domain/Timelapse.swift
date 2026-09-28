@preconcurrency import AVFoundation
import CoreImage
import Foundation
import Vision

struct TimelapseFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
}

struct TimelapseRenderReport: Codable, Equatable, Sendable {
    let sourceFrameCount: Int
    let blendedMotionTransitions: Int
    let motionFallbackTransitions: Int

    init(sourceFrameCount: Int, blendedMotionTransitions: Int, motionFallbackTransitions: Int = 0) {
        self.sourceFrameCount = sourceFrameCount
        self.blendedMotionTransitions = blendedMotionTransitions
        self.motionFallbackTransitions = motionFallbackTransitions
    }

    private enum CodingKeys: String, CodingKey {
        case sourceFrameCount, blendedMotionTransitions, motionFallbackTransitions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceFrameCount = try container.decode(Int.self, forKey: .sourceFrameCount)
        blendedMotionTransitions = try container.decode(Int.self, forKey: .blendedMotionTransitions)
        motionFallbackTransitions = try container.decodeIfPresent(Int.self, forKey: .motionFallbackTransitions) ?? 0
    }
}

struct TimelapseRenderDocument: Codable, Sendable {
    let settings: TimelapseSettings
    let report: TimelapseRenderReport

    static func load(in rootURL: URL) throws -> Self? {
        let url = rootURL.appending(path: "timelapse-render.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func save(in rootURL: URL) throws {
        try JSONEncoder().encode(self).write(to: rootURL.appending(path: "timelapse-render.json"), options: .atomic)
    }
}

enum TimelapseError: LocalizedError {
    case invalidSource
    case frameSizeMismatch
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidSource: "The saved timelapse frames could not be read."
        case .frameSizeMismatch: "A timelapse frame does not match the recording canvas."
        case .writerFailed(let message): "The timelapse movie could not be saved. \(message)"
        }
    }
}

/// The immutable source contains one selected, composed frame per media second.
/// Its media clock is independent of capture time and later playback pace.
actor TimelapseSourceWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let outputURL: URL
    private let canvasSize: CGSize
    private let frameRate: Int
    private(set) var frameCount = 0

    init(outputURL: URL, canvasSize: CGSize, frameRate: Int = 1, codecPolicy: RecordingCodecPolicy = .h264) throws {
        self.outputURL = outputURL
        self.canvasSize = canvasSize
        self.frameRate = frameRate
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        self.writer = writer
        writer.initialMovieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        let codecs: [AVVideoCodecType] = codecPolicy == .automatic ? [.hevc, .h264] : [.h264]
        let codec = codecs.first { writer.canApply(outputSettings: [
            AVVideoCodecKey: $0, AVVideoWidthKey: Int(canvasSize.width), AVVideoHeightKey: Int(canvasSize.height)
        ], forMediaType: .video) } ?? .h264
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: Int(canvasSize.width), AVVideoHeightKey: Int(canvasSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(1_000_000, Int(canvasSize.width * canvasSize.height * (frameRate == 1 ? 4 : Double(frameRate) * 0.35))),
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw TimelapseError.writerFailed("Video encoding is unavailable.") }
        writer.add(input)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.startWriting() else { throw TimelapseError.writerFailed(writer.error?.localizedDescription ?? "") }
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ frame: TimelapseFrame) async throws {
        guard CVPixelBufferGetWidth(frame.pixelBuffer) == Int(canvasSize.width),
              CVPixelBufferGetHeight(frame.pixelBuffer) == Int(canvasSize.height) else {
            throw TimelapseError.frameSizeMismatch
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer.status == .writing, ContinuousClock.now < deadline else {
                throw TimelapseError.writerFailed(writer.error?.localizedDescription ?? "The encoder stopped accepting frames.")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard adaptor.append(frame.pixelBuffer, withPresentationTime: CMTime(value: Int64(frameCount), timescale: Int32(frameRate))) else {
            throw TimelapseError.writerFailed(writer.error?.localizedDescription ?? "Frame encoding failed.")
        }
        frameCount += 1
    }

    func finish() async throws -> URL {
        guard frameCount > 0 else { throw TimelapseError.invalidSource }
        if writer.status == .completed { return outputURL }
        writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: Int32(frameRate)))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw TimelapseError.writerFailed(writer.error?.localizedDescription ?? "") }
        return outputURL
    }
}

actor TimelapseMovieRenderer {
    static let frameRate = 30
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let motionInterpolator = CIKernel(source: """
        kernel vec4 timelapseMotionInterpolate(
            sampler first, sampler second, sampler flow, float fraction, float scaleX, float scaleY
        ) {
            vec2 outputPoint = destCoord();
            vec2 initialFlow = sample(flow, samplerTransform(flow, outputPoint)).xy * vec2(scaleX, scaleY);
            vec2 initialPoint = outputPoint - fraction * initialFlow;
            vec2 displacement = sample(flow, samplerTransform(flow, initialPoint)).xy * vec2(scaleX, scaleY);
            vec2 firstPoint = outputPoint - fraction * displacement;
            vec2 secondPoint = firstPoint + displacement;
            vec4 firstColor = sample(first, samplerTransform(first, firstPoint));
            vec4 secondColor = sample(second, samplerTransform(second, secondPoint));
            return mix(firstColor, secondColor, fraction);
        }
        """)

    func exportMovie(
        from sourceURL: URL,
        settings: TimelapseSettings,
        codecPolicy: RecordingCodecPolicy = .h264,
        to destinationURL: URL,
        progress: @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws -> TimelapseRenderReport {
        let source = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let destination = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
        guard source != destination,
              source.deletingLastPathComponent().lastPathComponent != "raw-tracks"
                || destination.deletingLastPathComponent() != source.deletingLastPathComponent() else {
            throw ProjectEditRendererError.unsafeDestination
        }
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw TimelapseError.invalidSource
        }
        let size = try await track.load(.naturalSize)
        let sourceDuration = try await asset.load(.duration).seconds
        guard sourceDuration.isFinite, sourceDuration >= 1, sourceDuration < 10_000_000 else {
            throw TimelapseError.invalidSource
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        guard reader.canAdd(output) else { throw TimelapseError.invalidSource }
        reader.add(output)
        guard reader.startReading(), let first = output.copyNextSampleBuffer(), first.imageBuffer != nil else {
            throw TimelapseError.invalidSource
        }
        defer { reader.cancelReading() }
        let temporaryURL = destinationURL.deletingLastPathComponent().appending(path: ".timelapse-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let writer = try TimelapseSourceWriter(outputURL: temporaryURL, canvasSize: size,
                                              frameRate: Self.frameRate, codecPolicy: codecPolicy)
        let settings = settings.validated()
        let framesPerSample = Int((settings.frameDuration * Double(Self.frameRate)).rounded())
        var current = first
        var count = 0
        var blendedMotionTransitions = 0
        var motionFallbackTransitions = 0
        while true {
            try Task.checkCancellation()
            let next = output.copyNextSampleBuffer()
            guard let currentBuffer = current.imageBuffer,
                  abs(current.presentationTimeStamp.seconds - Double(count)) < 0.05 else {
                throw TimelapseError.invalidSource
            }
            let image = CIImage(cvPixelBuffer: currentBuffer)
            let nextImage = next?.imageBuffer.map(CIImage.init(cvPixelBuffer:))
            let flowMap: (image: CIImage, scaleX: CGFloat, scaleY: CGFloat)?
            let shouldInterpolateMotion = settings.transition == .motion && nextImage != nil
            if settings.transition == .motion, let nextImage {
                flowMap = try? makeOpticalFlow(from: image, to: nextImage)
            } else {
                flowMap = nil
            }
            var usedMotionInterpolation = false
            var usedMotionFallback = shouldInterpolateMotion && (flowMap == nil || motionInterpolator == nil)
            for frameIndex in 0..<framesPerSample {
                try Task.checkCancellation()
                let fraction = Double(frameIndex) / Double(framesPerSample)
                let rendered: CIImage
                if let nextImage, let flowMap, let motionInterpolator {
                    let bounds = CGRect(origin: .zero, size: size)
                    let interpolated = motionInterpolator.apply(
                        extent: bounds,
                        roiCallback: { _, _ in bounds },
                        arguments: [
                            image,
                            nextImage,
                            flowMap.image,
                            NSNumber(value: fraction),
                            NSNumber(value: Double(flowMap.scaleX)),
                            NSNumber(value: Double(flowMap.scaleY)),
                        ]
                    )
                    if let interpolated {
                        rendered = interpolated
                        usedMotionInterpolation = true
                    } else {
                        usedMotionFallback = true
                        rendered = image.applyingFilter("CIDissolveTransition", parameters: [
                            kCIInputTargetImageKey: nextImage, kCIInputTimeKey: fraction
                        ])
                    }
                } else if let nextImage {
                    rendered = image.applyingFilter("CIDissolveTransition", parameters: [
                        kCIInputTargetImageKey: nextImage, kCIInputTimeKey: fraction
                    ])
                } else {
                    rendered = image
                }
                var buffer: CVPixelBuffer?
                guard CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                                          kCVPixelFormatType_32BGRA,
                                          [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                          &buffer) == kCVReturnSuccess, let buffer else {
                    throw TimelapseError.writerFailed("The output canvas is unavailable.")
                }
                context.render(rendered, to: buffer, bounds: CGRect(origin: .zero, size: size),
                               colorSpace: CGColorSpaceCreateDeviceRGB())
                try await writer.append(TimelapseFrame(pixelBuffer: buffer))
            }
            if usedMotionInterpolation { blendedMotionTransitions += 1 }
            if usedMotionFallback { motionFallbackTransitions += 1 }
            count += 1
            await progress(min(Double(count) / sourceDuration, 1))
            guard let next else { break }
            current = next
        }
        guard reader.status == .completed else { throw TimelapseError.invalidSource }
        _ = try await writer.finish()
        let exported = AVURLAsset(url: temporaryURL)
        let expectedDuration = Double(count * framesPerSample) / Double(Self.frameRate)
        guard await RecordingOutputFinalizationPolicy.isCompleteProgram(
            isReadable: (try? exported.load(.isReadable)) == true,
            actualDuration: (try? exported.load(.duration).seconds) ?? 0,
            expectedDuration: expectedDuration,
            videoTrackCount: (try? exported.loadTracks(withMediaType: .video).count) ?? 0,
            audioTrackCount: (try? exported.loadTracks(withMediaType: .audio).count) ?? -1,
            expectedAudioTrackCount: 0
        ) else { throw TimelapseError.invalidSource }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        }
        return TimelapseRenderReport(
            sourceFrameCount: count,
            blendedMotionTransitions: blendedMotionTransitions,
            motionFallbackTransitions: motionFallbackTransitions
        )
    }

    private func makeOpticalFlow(from first: CIImage, to second: CIImage) throws -> (
        image: CIImage, scaleX: CGFloat, scaleY: CGFloat
    ) {
        let extent = first.extent.integral
        guard extent.width > 0, extent.height > 0, second.extent.integral == extent else {
            throw TimelapseError.invalidSource
        }
        let maximumDimension: CGFloat = 960
        let analysisScale = min(1, maximumDimension / max(extent.width, extent.height))
        let analysisSize = CGSize(
            width: max(1, (extent.width * analysisScale).rounded()),
            height: max(1, (extent.height * analysisScale).rounded())
        )
        let transform = CGAffineTransform(scaleX: analysisSize.width / extent.width,
                                          y: analysisSize.height / extent.height)
        let analysisBounds = CGRect(origin: .zero, size: analysisSize)
        guard let firstImage = context.createCGImage(
            first.transformed(by: transform).cropped(to: analysisBounds), from: analysisBounds
        ), let secondImage = context.createCGImage(
            second.transformed(by: transform).cropped(to: analysisBounds), from: analysisBounds
        ) else { throw TimelapseError.invalidSource }

        func flowImage(from source: CGImage, to target: CGImage) throws -> CIImage {
            let request = VNGenerateOpticalFlowRequest(targetedCGImage: target)
            request.computationAccuracy = .high
            request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
            try VNImageRequestHandler(cgImage: source, options: [:]).perform([request])
            guard let buffer = request.results?.first?.pixelBuffer else { throw TimelapseError.invalidSource }
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            guard width > 0, height > 0,
                  CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_TwoComponent32Float,
                  CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
                throw TimelapseError.invalidSource
            }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw TimelapseError.invalidSource }
            let input = base.assumingMemoryBound(to: Float.self)
            let inputRowStride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float>.size
            var rgba = [Float](repeating: 0, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let inputIndex = y * inputRowStride + x * 2
                    let outputIndex = (y * width + x) * 4
                    rgba[outputIndex] = input[inputIndex]
                    rgba[outputIndex + 1] = input[inputIndex + 1]
                    rgba[outputIndex + 3] = 1
                }
            }
            let data = rgba.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
            let flowScale = CGAffineTransform(scaleX: extent.width / CGFloat(width),
                                               y: extent.height / CGFloat(height))
            return CIImage(
                bitmapData: data,
                bytesPerRow: width * 4 * MemoryLayout<Float>.size,
                size: CGSize(width: width, height: height),
                format: .RGBAf,
                colorSpace: nil
            ).transformed(by: flowScale).cropped(to: extent)
        }

        return (try flowImage(from: firstImage, to: secondImage),
                extent.width / analysisSize.width,
                extent.height / analysisSize.height)
    }
}
