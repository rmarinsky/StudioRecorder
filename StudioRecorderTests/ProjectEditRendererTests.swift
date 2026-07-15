@preconcurrency import AVFoundation
import ImageIO
import XCTest
@testable import StudioRecorder

final class ProjectEditRendererTests: XCTestCase {
    func testProgramRendererRemovesGreenCameraBackgroundOverTheScreen() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appending(path: "screen.mov")
        let cameraURL = directory.appending(path: "green-camera.mov")
        let outputURL = directory.appending(path: "program.mov")
        let frameURL = directory.appending(path: "program.png")
        try await writeReadableMovie(to: screenURL, colors: Array(repeating: 0xFFFF0000, count: 5))
        try await writeReadableMovie(to: cameraURL, colors: Array(repeating: 0xFF00FF00, count: 5))

        var presentation = CapturePresentationSnapshot.default
        presentation.canvas = CaptureCanvasSnapshot(width: 640, height: 360)
        presentation.camera = SourcePlacementSnapshot(
            centerX: 0.5,
            centerY: 0.5,
            width: 1,
            height: 1,
            shape: .rectangle
        )
        presentation.cameraBackground = CameraBackgroundSnapshot(mode: .greenScreen)

        try await ProjectProgramRenderer().exportMovie(
            sources: ProjectProgramSources(screenURL: screenURL, cameraURL: cameraURL),
            timeline: try ProjectEditTimeline(trackID: "screen-3", sourceDuration: 2),
            presentation: presentation,
            to: outputURL
        )
        try await ProjectMediaExporter().exportScreenshot(from: outputURL, at: 0.5, to: frameURL)

        let center = try color(in: frameURL, normalizedX: 0.5, normalizedY: 0.5)
        XCTAssertGreaterThan(center.red, 180)
        XCTAssertLessThan(center.green, 80)
    }

    func testFollowCursorSceneReplaysRecordedCursorMovement() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appending(path: "split-screen.mov")
        let outputURL = directory.appending(path: "follow-program.mov")
        let leftFrameURL = directory.appending(path: "left.png")
        let rightFrameURL = directory.appending(path: "right.png")
        try await writeSplitMovie(to: screenURL)

        var presentation = CapturePresentationSnapshot.default
        presentation.canvas = CaptureCanvasSnapshot(width: 640, height: 640)
        presentation.framing = ScreenFramingSnapshot(mode: .followCursor, scale: 0.5)
        presentation.camera.isVisible = false
        let cursor = CursorSceneTimeline(samples: [
            CursorSceneSample(time: 0, displayID: 7, normalizedX: 0.1, normalizedY: 0.5, isPrimaryButtonDown: false),
            CursorSceneSample(time: 1, displayID: 7, normalizedX: 0.9, normalizedY: 0.5, isPrimaryButtonDown: false),
        ])

        try await ProjectProgramRenderer().exportMovie(
            sources: ProjectProgramSources(
                screenURL: screenURL,
                cameraURL: nil,
                screenDisplayID: 7,
                cursorTimeline: cursor
            ),
            timeline: try ProjectEditTimeline(trackID: "screen-7", sourceDuration: 2),
            presentation: presentation,
            to: outputURL
        )
        try await ProjectMediaExporter().exportScreenshot(from: outputURL, at: 0.25, to: leftFrameURL)
        try await ProjectMediaExporter().exportScreenshot(from: outputURL, at: 1.25, to: rightFrameURL)

        let left = try color(in: leftFrameURL, normalizedX: 0.5, normalizedY: 0.5)
        let right = try color(in: rightFrameURL, normalizedX: 0.5, normalizedY: 0.5)
        XCTAssertGreaterThan(left.red, 180)
        XCTAssertLessThan(left.blue, 80)
        XCTAssertGreaterThan(right.blue, 180)
        XCTAssertLessThan(right.red, 80)
    }

    func testProgramRendererComposesIndependentlyPlacedScreenAndCameraSources() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appending(path: "screen.mov")
        let cameraURL = directory.appending(path: "camera.mov")
        let outputURL = directory.appending(path: "program.mov")
        let frameURL = directory.appending(path: "program.png")
        try await writeReadableMovie(to: screenURL, colors: Array(repeating: 0xFFFF0000, count: 5))
        try await writeReadableMovie(to: cameraURL, colors: Array(repeating: 0xFF00FF00, count: 5))

        let timeline = try ProjectEditTimeline(trackID: "screen-3", sourceDuration: 2)
        var presentation = CapturePresentationSnapshot.default
        presentation.canvas = CaptureCanvasSnapshot(width: 640, height: 360)
        presentation.camera = SourcePlacementSnapshot(
            centerX: 0.5,
            centerY: 0.5,
            width: 0.5,
            height: 0.5,
            shape: .circle
        )

        try await ProjectProgramRenderer().exportMovie(
            sources: ProjectProgramSources(screenURL: screenURL, cameraURL: cameraURL),
            timeline: timeline,
            presentation: presentation,
            to: outputURL
        )
        try await ProjectMediaExporter().exportScreenshot(from: outputURL, at: 0.5, to: frameURL)

        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(frameURL as CFURL, nil))
        let renderedFrame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(renderedFrame.width, 640)
        XCTAssertEqual(renderedFrame.height, 360)
        let center = try color(in: frameURL, normalizedX: 0.5, normalizedY: 0.5)
        let corner = try color(in: frameURL, normalizedX: 0.05, normalizedY: 0.05)
        XCTAssertGreaterThan(center.green, 180)
        XCTAssertLessThan(center.red, 80)
        XCTAssertGreaterThan(corner.red, 180)
        XCTAssertLessThan(corner.green, 80)
    }

    func testProgramRendererFallsBackToScreenWhenOptionalCameraIsUnreadable() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appending(path: "screen.mov")
        let outputURL = directory.appending(path: "program.mov")
        let frameURL = directory.appending(path: "program.png")
        try await writeReadableMovie(to: screenURL, colors: Array(repeating: 0xFFFF0000, count: 5))

        try await ProjectProgramRenderer().exportMovie(
            sources: ProjectProgramSources(
                screenURL: screenURL,
                cameraURL: directory.appending(path: "missing-camera.mov")
            ),
            timeline: try ProjectEditTimeline(trackID: "screen-3", sourceDuration: 2),
            presentation: .default,
            to: outputURL
        )
        try await ProjectMediaExporter().exportScreenshot(from: outputURL, at: 0.5, to: frameURL)

        let center = try color(in: frameURL, normalizedX: 0.5, normalizedY: 0.5)
        XCTAssertGreaterThan(center.red, 180)
        XCTAssertLessThan(center.green, 80)
        XCTAssertLessThan(center.blue, 80)
    }

    func testRendererRejectsTheRawSourceAsAnExportDestinationWithoutDeletingIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appending(path: "source.mov")
        try await writeReadableMovie(to: sourceURL)
        let originalBytes = try Data(contentsOf: sourceURL)
        let timeline = try ProjectEditTimeline(trackID: "screen-3", sourceDuration: 2)

        do {
            try await ProjectEditRenderer().exportMovie(from: sourceURL, timeline: timeline, to: sourceURL)
            XCTFail("Expected an unsafe destination error")
        } catch {
            XCTAssertEqual(error as? ProjectEditRendererError, .unsafeDestination)
        }

        XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes)
    }

    func testRendererExportsOnlyTheOrderedSegmentsInTheEditTimeline() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appending(path: "source.mov")
        let outputURL = directory.appending(path: "edited.mov")
        let firstFrameURL = directory.appending(path: "first.png")
        let secondFrameURL = directory.appending(path: "second.png")
        try await writeReadableMovie(to: sourceURL)

        let firstID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let middleID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let lastID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        var timeline = try ProjectEditTimeline(trackID: "screen-3", sourceDuration: 2, initialSegmentID: firstID)
        try timeline.split(at: 0.5, newSegmentID: middleID)
        try timeline.split(at: 1.5, newSegmentID: lastID)
        try timeline.delete(segmentID: middleID)

        try await ProjectEditRenderer().exportMovie(from: sourceURL, timeline: timeline, to: outputURL)

        let output = AVURLAsset(url: outputURL)
        let outputDuration = try await output.load(.duration).seconds
        XCTAssertEqual(outputDuration, 1, accuracy: 0.08)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        let mediaExporter = ProjectMediaExporter()
        try await mediaExporter.exportScreenshot(from: outputURL, at: 0.1, to: firstFrameURL)
        try await mediaExporter.exportScreenshot(from: outputURL, at: 0.6, to: secondFrameURL)
        let firstColor = try averageColor(in: firstFrameURL)
        let secondColor = try averageColor(in: secondFrameURL)
        XCTAssertGreaterThan(firstColor.red, 180)
        XCTAssertLessThan(firstColor.green, 80)
        XCTAssertLessThan(firstColor.blue, 80)
        XCTAssertGreaterThan(secondColor.red, 180)
        XCTAssertGreaterThan(secondColor.green, 180)
        XCTAssertGreaterThan(secondColor.blue, 180)
    }

    private func writeReadableMovie(
        to url: URL,
        colors: [UInt32] = [0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFFFF, 0xFF000000]
    ) async throws {
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

        for (index, color) in colors.enumerated() {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(
                adaptor.append(
                    try pixelBuffer(color: color),
                    withPresentationTime: CMTime(seconds: Double(index) * 0.5, preferredTimescale: 600)
                )
            )
        }
        input.markAsFinished()

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "ProjectEditRendererTests", code: 1)
        }
    }

    private func writeSplitMovie(to url: URL) async throws {
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
        for index in 0..<5 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(
                adaptor.append(
                    try splitPixelBuffer(),
                    withPresentationTime: CMTime(seconds: Double(index) * 0.5, preferredTimescale: 600)
                )
            )
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "ProjectEditRendererTests", code: 2)
        }
    }

    private func averageColor(in url: URL) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixel,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (pixel[0], pixel[1], pixel[2])
    }

    private func color(
        in url: URL,
        normalizedX: CGFloat,
        normalizedY: CGFloat
    ) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixel,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        let sampleX = CGFloat(image.width) * min(max(normalizedX, 0), 1)
        let sampleY = CGFloat(image.height) * min(max(normalizedY, 0), 1)
        context.translateBy(x: -sampleX, y: -sampleY)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (pixel[0], pixel[1], pixel[2])
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
        let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt32.self)
        for y in 0..<64 {
            for x in 0..<64 {
                pixels[(y * rowPixels) + x] = color
            }
        }
        return pixelBuffer
    }

    private func splitPixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer),
            kCVReturnSuccess
        )
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let rowPixels = CVPixelBufferGetBytesPerRow(pixelBuffer) / MemoryLayout<UInt32>.size
        let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt32.self)
        for y in 0..<64 {
            for x in 0..<64 {
                pixels[(y * rowPixels) + x] = x < 32 ? 0xFFFF0000 : 0xFF0000FF
            }
        }
        return pixelBuffer
    }
}
