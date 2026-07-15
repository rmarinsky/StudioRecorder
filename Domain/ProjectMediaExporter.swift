@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ProjectMediaExportError: LocalizedError, Equatable {
    case invalidAssetDuration
    case invalidStartTime
    case invalidClipDuration
    case unreadableMovie
    case destinationCreationFailed
    case destinationWriteFailed

    var errorDescription: String? {
        switch self {
        case .invalidAssetDuration:
            "The selected movie does not have a usable duration."
        case .invalidStartTime:
            "Move the playhead inside the movie before exporting."
        case .invalidClipDuration:
            "The GIF clip needs a positive duration."
        case .unreadableMovie:
            "Studio Recorder could not read frames from the selected movie."
        case .destinationCreationFailed:
            "Studio Recorder could not create the requested image file."
        case .destinationWriteFailed:
            "Studio Recorder could not finish writing the requested image file."
        }
    }
}

actor ProjectMediaExporter {
    func exportScreenshot(from sourceURL: URL, at time: TimeInterval, to destinationURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let assetDuration = try await readableDuration(of: asset)
        let safeTime = min(max(time.isFinite ? time : 0, 0), max(assetDuration - (1 / 600), 0))
        let generator = imageGenerator(for: asset, maxPixelWidth: nil)
        let generated = try await generator.image(at: CMTime(seconds: safeTime, preferredTimescale: 600))

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ProjectMediaExportError.destinationCreationFailed
        }
        CGImageDestinationAddImage(destination, generated.image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ProjectMediaExportError.destinationWriteFailed
        }
        try Data(referencing: data).write(to: destinationURL, options: .atomic)
    }

    func exportGIF(from sourceURL: URL, settings: GIFExportSettings, to destinationURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let plan = try settings.plan(assetDuration: try await readableDuration(of: asset))
        let generator = imageGenerator(for: asset, maxPixelWidth: plan.maxPixelWidth)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.gif.identifier as CFString,
            plan.frameTimes.count,
            nil
        ) else {
            throw ProjectMediaExportError.destinationCreationFailed
        }

        CGImageDestinationSetProperties(
            destination,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: plan.imageIOLoopCount]] as CFDictionary
        )
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: 1 / plan.framesPerSecond,
                kCGImagePropertyGIFUnclampedDelayTime: 1 / plan.framesPerSecond,
            ],
        ] as CFDictionary

        for time in plan.frameTimes {
            try Task.checkCancellation()
            let generated = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
            CGImageDestinationAddImage(destination, generated.image, frameProperties)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw ProjectMediaExportError.destinationWriteFailed
        }
        try Data(referencing: data).write(to: destinationURL, options: .atomic)
    }

    private func readableDuration(of asset: AVURLAsset) async throws -> TimeInterval {
        guard (try? await asset.load(.isReadable)) == true,
              let duration = try? await asset.load(.duration),
              duration.isNumeric,
              duration.seconds.isFinite,
              duration.seconds > 0 else {
            throw ProjectMediaExportError.unreadableMovie
        }
        return duration.seconds
    }

    private func imageGenerator(for asset: AVAsset, maxPixelWidth: Int?) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if let maxPixelWidth {
            generator.maximumSize = CGSize(width: maxPixelWidth, height: maxPixelWidth)
        }
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        return generator
    }
}

struct GIFExportPlan: Equatable, Sendable {
    let startTime: TimeInterval
    let duration: TimeInterval
    let framesPerSecond: Double
    let maxPixelWidth: Int
    let loops: Bool
    let frameTimes: [TimeInterval]

    var imageIOLoopCount: Int { loops ? 0 : 1 }
}

struct GIFExportSettings: Equatable, Sendable {
    let startTime: TimeInterval
    let duration: TimeInterval
    let framesPerSecond: Double
    let maxPixelWidth: Int
    let loops: Bool

    init(
        startTime: TimeInterval,
        duration: TimeInterval = 5,
        framesPerSecond: Double = 10,
        maxPixelWidth: Int = 960,
        loops: Bool = true
    ) {
        self.startTime = startTime
        self.duration = duration
        self.framesPerSecond = framesPerSecond
        self.maxPixelWidth = maxPixelWidth
        self.loops = loops
    }

    func plan(assetDuration: TimeInterval) throws -> GIFExportPlan {
        guard assetDuration.isFinite, assetDuration > 0 else {
            throw ProjectMediaExportError.invalidAssetDuration
        }
        guard startTime.isFinite, startTime >= 0, startTime < assetDuration else {
            throw ProjectMediaExportError.invalidStartTime
        }
        guard duration.isFinite, duration > 0 else {
            throw ProjectMediaExportError.invalidClipDuration
        }

        let safeFPS = min(max(framesPerSecond.isFinite ? framesPerSecond : 10, 1), 15)
        let safeWidth = min(max(maxPixelWidth, 160), 1_280)
        let safeDuration = min(duration, 15, assetDuration - startTime)
        let frameCount = max(1, Int(floor(safeDuration * safeFPS)))
        let frameTimes = (0..<frameCount).map { startTime + (Double($0) / safeFPS) }

        return GIFExportPlan(
            startTime: startTime,
            duration: safeDuration,
            framesPerSecond: safeFPS,
            maxPixelWidth: safeWidth,
            loops: loops,
            frameTimes: frameTimes
        )
    }
}
