@preconcurrency import AVFoundation
import ImageIO
import XCTest
@testable import StudioRecorder

final class ProjectMediaExporterTests: XCTestCase {
    @MainActor
    func testTimelapseCaptureSkipsPausedTicksAndDoesNotAppendAFrameThatArrivesAfterStop() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appending(path: "frames.mov")
        let frame = TimelapseFrame(pixelBuffer: try pixelBuffer(color: 0xFFFF0000))
        var pendingFrame: CheckedContinuation<TimelapseFrame, Error>?
        var requests = 0
        let session = try TimelapseCaptureSession(
            outputURL: sourceURL, canvasSize: CGSize(width: 64, height: 64),
            settings: TimelapseSettings(captureInterval: 1),
            frameProvider: {
                requests += 1
                if requests == 1 { return frame }
                return try await withCheckedThrowingContinuation { pendingFrame = $0 }
            }
        )
        try await session.start()
        session.pause()
        try await Task.sleep(for: .milliseconds(1_100))
        XCTAssertEqual(session.frameCount, 1)
        XCTAssertEqual(requests, 1)
        session.resume()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while pendingFrame == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let continuation = try XCTUnwrap(pendingFrame)
        let stopping = Task { try await session.stop() }
        await Task.yield()
        continuation.resume(returning: frame)
        _ = try await stopping.value
        XCTAssertEqual(session.frameCount, 1)
        let duration = try await AVURLAsset(url: sourceURL).load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.02)
    }

    func testTimelapseRendersOnlySelectedFramesAtTheConfiguredPaceWithoutAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appending(path: "selected-frames.mov")
        let outputURL = directory.appending(path: "timelapse.mov")
        let source = try TimelapseSourceWriter(outputURL: sourceURL, canvasSize: CGSize(width: 64, height: 64))
        for color: UInt32 in [0xFFFF0000, 0xFF0000FF, 0xFF00FF00] {
            try await source.append(TimelapseFrame(pixelBuffer: try pixelBuffer(color: color)))
        }
        _ = try await source.finish()

        let report = try await TimelapseMovieRenderer().exportMovie(
            from: sourceURL, settings: TimelapseSettings(frameDuration: 0.2),
            to: outputURL
        )

        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration).seconds
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(duration, 0.6, accuracy: 0.02)
        XCTAssertTrue(audioTracks.isEmpty)
        XCTAssertEqual(report.sourceFrameCount, 3)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let midpoint = try await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
        let context = CIContext()
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(CIImage(cgImage: midpoint), toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 32, y: 32, width: 1, height: 1), format: .RGBA8,
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        XCTAssertGreaterThan(pixel[0], 80, "The midpoint must contain both neighboring colors")
        XCTAssertGreaterThan(pixel[2], 80)
        XCTAssertLessThan(pixel[1], 50, "Allow chroma rounding from the native video encoder")
    }

    func testGIFExportSettingsClampTheShareClipToAvailableMediaAndSafeLimits() throws {
        let settings = GIFExportSettings(
            startTime: 8,
            duration: 20,
            framesPerSecond: 24,
            maxPixelWidth: 4_000,
            loops: false
        )

        let plan = try settings.plan(assetDuration: 12)

        XCTAssertEqual(plan.startTime, 8, accuracy: 0.001)
        XCTAssertEqual(plan.duration, 4, accuracy: 0.001)
        XCTAssertEqual(plan.framesPerSecond, 15, accuracy: 0.001)
        XCTAssertEqual(plan.maxPixelWidth, 1_280)
        XCTAssertFalse(plan.loops)
        XCTAssertEqual(plan.imageIOLoopCount, 1)
        XCTAssertEqual(plan.frameTimes.first, 8)
        XCTAssertEqual(try XCTUnwrap(plan.frameTimes.last), 11.933333, accuracy: 0.001)
        XCTAssertEqual(plan.frameTimes.count, 60)
    }

    func testExporterCreatesPNGAndAnimatedGIFFromAReadableMovie() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movieURL = directory.appending(path: "source.mov")
        let firstScreenshotURL = directory.appending(path: "frame-start.png")
        let secondScreenshotURL = directory.appending(path: "frame-middle.png")
        let gifURL = directory.appending(path: "clip.gif")
        let oneShotGIFURL = directory.appending(path: "clip-once.gif")
        try await writeReadableMovie(to: movieURL)

        let exporter = ProjectMediaExporter()
        try await exporter.exportScreenshot(from: movieURL, at: 0, to: firstScreenshotURL)
        try await exporter.exportScreenshot(from: movieURL, at: 0.5, to: secondScreenshotURL)
        try await exporter.exportGIF(
            from: movieURL,
            settings: GIFExportSettings(startTime: 0, duration: 1, framesPerSecond: 5, maxPixelWidth: 320),
            to: gifURL
        )
        try await exporter.exportGIF(
            from: movieURL,
            settings: GIFExportSettings(
                startTime: 0,
                duration: 1,
                framesPerSecond: 5,
                maxPixelWidth: 320,
                loops: false
            ),
            to: oneShotGIFURL
        )

        let firstScreenshot = try XCTUnwrap(CGImageSourceCreateWithURL(firstScreenshotURL as CFURL, nil))
        let secondScreenshot = try XCTUnwrap(CGImageSourceCreateWithURL(secondScreenshotURL as CFURL, nil))
        let gif = try XCTUnwrap(CGImageSourceCreateWithURL(gifURL as CFURL, nil))
        let oneShotGIF = try XCTUnwrap(CGImageSourceCreateWithURL(oneShotGIFURL as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(firstScreenshot), 1)
        XCTAssertEqual(CGImageSourceGetCount(secondScreenshot), 1)
        XCTAssertNotEqual(
            imageBytes(try XCTUnwrap(CGImageSourceCreateImageAtIndex(firstScreenshot, 0, nil))),
            imageBytes(try XCTUnwrap(CGImageSourceCreateImageAtIndex(secondScreenshot, 0, nil)))
        )
        XCTAssertGreaterThan(CGImageSourceGetCount(gif), 1)
        XCTAssertNotEqual(
            imageBytes(try XCTUnwrap(CGImageSourceCreateImageAtIndex(gif, 0, nil))),
            imageBytes(try XCTUnwrap(CGImageSourceCreateImageAtIndex(gif, CGImageSourceGetCount(gif) - 1, nil)))
        )
        XCTAssertEqual(gifLoopCount(gif), 0)
        XCTAssertEqual(gifLoopCount(oneShotGIF), 1)
    }

    private func writeReadableMovie(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 64,
                AVVideoHeightKey: 64,
            ]
        )
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for (color, time) in [
            (UInt32(0xFFFF0000), CMTime.zero),
            (UInt32(0xFF00FF00), CMTime(seconds: 0.5, preferredTimescale: 600)),
            (UInt32(0xFF0000FF), CMTime(seconds: 1, preferredTimescale: 600)),
        ] {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(adaptor.append(try pixelBuffer(color: color), withPresentationTime: time))
        }
        input.markAsFinished()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if writer.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: writer.error ?? NSError(domain: "ProjectMediaExporterTests", code: 1))
                }
            }
        }
    }

    private func pixelBuffer(color: UInt32) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer),
            kCVReturnSuccess
        )
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let rowPixels = CVPixelBufferGetBytesPerRow(pixelBuffer) / MemoryLayout<UInt32>.size
        let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
            .assumingMemoryBound(to: UInt32.self)
        for y in 0..<64 {
            for x in 0..<64 {
                pixels[(y * rowPixels) + x] = color
            }
        }
        return pixelBuffer
    }

    private func imageBytes(_ image: CGImage) -> Data? {
        guard let data = image.dataProvider?.data else { return nil }
        return data as Data
    }

    private func gifLoopCount(_ source: CGImageSource) -> Int? {
        guard let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return nil }
        return gif[kCGImagePropertyGIFLoopCount] as? Int
    }
}
