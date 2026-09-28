@preconcurrency import AVFoundation
import CoreImage
import Foundation

struct TimelapseFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
}

struct TimelapseRenderReport: Codable, Equatable, Sendable {
    let sourceFrameCount: Int
    let blendedMotionTransitions: Int
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
        while true {
            try Task.checkCancellation()
            let next = output.copyNextSampleBuffer()
            guard let currentBuffer = current.imageBuffer,
                  abs(current.presentationTimeStamp.seconds - Double(count)) < 0.05 else {
                throw TimelapseError.invalidSource
            }
            let image = CIImage(cvPixelBuffer: currentBuffer)
            let nextImage = next?.imageBuffer.map(CIImage.init(cvPixelBuffer:))
            for frameIndex in 0..<framesPerSample {
                try Task.checkCancellation()
                let fraction = Double(frameIndex) / Double(framesPerSample)
                let rendered = nextImage.map {
                    image.applyingFilter("CIDissolveTransition", parameters: [
                        kCIInputTargetImageKey: $0, kCIInputTimeKey: fraction
                    ])
                } ?? image
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
        return TimelapseRenderReport(sourceFrameCount: count, blendedMotionTransitions: 0)
    }
}
