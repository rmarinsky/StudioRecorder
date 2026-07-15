import CoreGraphics
import CoreImage
import ImageIO
import XCTest
@testable import StudioRecorder

final class LiveSceneSnapshotExporterTests: XCTestCase {
    func testDisabledCameraNeverLeaksAnAvailableFrameIntoSnapshot() throws {
        let available = try solidPixelBuffer(red: 255, green: 0, blue: 0, width: 1, height: 1)

        let selected = try LiveSceneSnapshotCaptureError.cameraFrame(
            capturesCamera: false,
            cameraIsVisible: true,
            availableFrame: available
        )

        XCTAssertNil(selected)
    }

    func testVisibleEnabledCameraMustHaveAReadyFrame() {
        XCTAssertThrowsError(
            try LiveSceneSnapshotCaptureError.cameraFrame(
                capturesCamera: true,
                cameraIsVisible: true,
                availableFrame: nil
            )
        ) { error in
            XCTAssertEqual(error as? LiveSceneSnapshotCaptureError, .cameraUnavailable)
        }
    }

    func testHiddenCameraDoesNotBlockSnapshotWhileStarting() throws {
        let selected = try LiveSceneSnapshotCaptureError.cameraFrame(
            capturesCamera: true,
            cameraIsVisible: false,
            availableFrame: nil
        )

        XCTAssertNil(selected)
    }

    func testExporterSavesTheComposedStageAtTheConfiguredCanvasSize() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "stage.png")

        var presentation = CapturePresentationSnapshot.default
        presentation.canvas = CaptureCanvasSnapshot(width: 640, height: 360)
        presentation.screen = SourcePlacementSnapshot(
            centerX: 0.5,
            centerY: 0.5,
            width: 1,
            shape: .rectangle
        )
        presentation.camera = SourcePlacementSnapshot(
            centerX: 0.5,
            centerY: 0.5,
            width: 0.5,
            height: 0.5,
            shape: .circle
        )

        let exporter = LiveSceneSnapshotExporter()
        try await exporter.export(
            sources: LiveSceneSnapshotSources(
                screen: try solidImage(red: 0, green: 0, blue: 1, width: 640, height: 360),
                camera: try solidPixelBuffer(red: 255, green: 0, blue: 0, width: 64, height: 64)
            ),
            presentation: presentation,
            screenFraming: nil,
            cursor: nil,
            to: destination
        )

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(destination as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 640)
        XCTAssertEqual(image.height, 360)
        let center = try rgba(in: image, x: 320, y: 180)
        let corner = try rgba(in: image, x: 10, y: 10)
        XCTAssertGreaterThan(center.red, 200, "center: \(center), corner: \(corner)")
        XCTAssertLessThan(center.blue, 50)
        XCTAssertLessThan(corner.red, 50)
        XCTAssertGreaterThan(corner.blue, 200)
    }

    private func solidImage(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        width: Int,
        height: Int
    ) throws -> CGImage {
        let image = CIImage(color: CIColor(red: red, green: green, blue: blue))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(CIContext().createCGImage(image, from: image.extent))
    }

    private func solidPixelBuffer(
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        width: Int,
        height: Int
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                nil,
                &buffer
            ),
            kCVReturnSuccess
        )
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let baseAddress = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
        for y in 0..<height {
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let offset = x * 4
                row[offset] = blue
                row[offset + 1] = green
                row[offset + 2] = red
                row[offset + 3] = 255
            }
        }
        return pixelBuffer
    }

    private func rgba(in image: CGImage, x: Int, y: Int) throws -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
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
        context.translateBy(x: -CGFloat(x), y: -CGFloat(y))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }
}
