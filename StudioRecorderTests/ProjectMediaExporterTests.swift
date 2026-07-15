@preconcurrency import AVFoundation
import ImageIO
import XCTest
@testable import StudioRecorder

final class ProjectMediaExporterTests: XCTestCase {
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
