import CoreGraphics
import CoreImage
import XCTest
@testable import StudioRecorder

final class CapturePresentationTests: XCTestCase {
    func testLegacyPresentationDefaultsCameraBackgroundToOff() throws {
        let encoded = try JSONEncoder().encode(CapturePresentationSnapshot.default)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "cameraBackground")
        object.removeValue(forKey: "name")

        let decoded = try JSONDecoder().decode(
            CapturePresentationSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.resolvedCameraBackground, .off)
        XCTAssertEqual(decoded.resolvedName, "Scene 1")
    }

    func testSceneNameIsBoundedAndBlankNamesResolveToTheDefault() {
        var presentation = CapturePresentationSnapshot.default
        presentation.name = String(repeating: "a", count: 100)
        XCTAssertEqual(presentation.validated().name?.count, 80)

        presentation.name = "   "
        XCTAssertEqual(presentation.validated().resolvedName, "Scene 1")
    }

    func testGreenScreenMakesTheKeyColorTransparentAndKeepsForegroundObjects() throws {
        let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: extent)
        let foregroundRect = CGRect(x: 20, y: 20, width: 24, height: 24)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: foregroundRect)
        let source = red.composited(over: green)
        let processed = CameraBackgroundProcessor(personQuality: .export).process(
            source,
            background: CameraBackgroundSnapshot(mode: .greenScreen)
        )
        let cgImage = try XCTUnwrap(CIContext().createCGImage(processed, from: extent))

        let keyed = try rgba(in: cgImage, x: 4, y: 4)
        let foreground = try rgba(in: cgImage, x: 32, y: 32)
        XCTAssertLessThan(keyed.alpha, 30)
        XCTAssertGreaterThan(foreground.alpha, 220)
        XCTAssertGreaterThan(foreground.red, 180)
        XCTAssertLessThan(foreground.green, 80)
    }

    func testCanvasPresetsCoverHorizontalVerticalAndSixteenByTenOutputs() {
        XCTAssertEqual(CaptureCanvasPreset.fullHD.pixelSize, CGSize(width: 1_920, height: 1_080))
        XCTAssertEqual(CaptureCanvasPreset.verticalHD.pixelSize, CGSize(width: 1_080, height: 1_920))
        XCTAssertEqual(CaptureCanvasPreset.widescreen16x10.pixelSize, CGSize(width: 1_920, height: 1_200))
    }

    func testFixedRegionKeepsCanvasAspectAndClampsToTheDisplay() {
        let framing = ScreenFramingSnapshot(
            mode: .fixedRegion,
            centerX: 0.95,
            centerY: 0.1,
            scale: 0.5
        )

        let region = CaptureGeometryPlanner.sourceRect(
            displaySize: CGSize(width: 3_440, height: 1_440),
            canvasSize: CaptureCanvasPreset.verticalHD.pixelSize,
            framing: framing
        )

        XCTAssertEqual(region.width / region.height, 9.0 / 16.0, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(region.minX, 0)
        XCTAssertGreaterThanOrEqual(region.minY, 0)
        XCTAssertLessThanOrEqual(region.maxX, 3_440)
        XCTAssertLessThanOrEqual(region.maxY, 1_440)
        XCTAssertEqual(region.maxX, 3_440, accuracy: 0.001)
        XCTAssertEqual(region.minY, 0, accuracy: 0.001)
    }

    func testSourcePlacementClampsScaleAndPositionInsideTheCanvas() {
        let placement = SourcePlacementSnapshot(
            centerX: 1.4,
            centerY: -0.2,
            width: 0.2,
            height: 0.3,
            shape: .roundedRectangle,
            cornerRadius: 0.08
        ).validated()

        XCTAssertEqual(placement.centerX, 0.9)
        XCTAssertEqual(placement.centerY, 0.15)
        XCTAssertEqual(placement.width, 0.2)
        XCTAssertEqual(placement.height, 0.3)
        XCTAssertEqual(placement.cornerRadius, 0.08)
    }

    func testFullCanvasSourceAlwaysCentersInsideTheCanvas() {
        let placement = SourcePlacementSnapshot(
            centerX: 1,
            centerY: 0,
            width: 2,
            height: 2,
            shape: .rectangle
        ).validated()

        XCTAssertEqual(placement.centerX, 0.5)
        XCTAssertEqual(placement.centerY, 0.5)
        XCTAssertEqual(placement.width, 1)
        XCTAssertEqual(placement.height, 1)
    }

    func testCameraAspectPresetsUsePixelAspectInsideHorizontalAndVerticalCanvases() {
        let placement = SourcePlacementSnapshot(
            centerX: 0.8,
            centerY: 0.7,
            width: 0.25,
            shape: .roundedRectangle
        )

        let portrait = placement.applying(
            aspectPreset: .portrait9x16,
            on: CaptureCanvasSnapshot(preset: .fullHD)
        )
        let landscape = placement.applying(
            aspectPreset: .landscape16x9,
            on: CaptureCanvasSnapshot(preset: .verticalHD)
        )

        XCTAssertEqual(portrait.width * (16.0 / 9.0) / portrait.height, 9.0 / 16.0, accuracy: 0.001)
        XCTAssertEqual(landscape.width * (9.0 / 16.0) / landscape.height, 16.0 / 9.0, accuracy: 0.001)
        XCTAssertEqual(portrait.matchingAspectPreset(on: CaptureCanvasSnapshot(preset: .fullHD)), .portrait9x16)
        XCTAssertEqual(landscape.matchingAspectPreset(on: CaptureCanvasSnapshot(preset: .verticalHD)), .landscape16x9)
    }

    func testFixedRegionStreamUsesTheCanvasOutputWhileFullDisplayPreservesNativePixels() {
        var presentation = CapturePresentationSnapshot.default
        presentation.canvas = CaptureCanvasSnapshot(preset: .verticalHD)
        presentation.framing = ScreenFramingSnapshot(mode: .fixedRegion, scale: 0.75)

        let fixed = CaptureGeometryPlanner.streamGeometry(
            displaySize: CGSize(width: 1_920, height: 1_080),
            pointPixelScale: 2,
            presentation: presentation
        )
        XCTAssertEqual(fixed.outputSize, CGSize(width: 1_080, height: 1_920))
        XCTAssertFalse(fixed.sourceRect.isEmpty)

        presentation.framing.mode = .fullDisplay
        let full = CaptureGeometryPlanner.streamGeometry(
            displaySize: CGSize(width: 1_920, height: 1_080),
            pointPixelScale: 2,
            presentation: presentation
        )
        XCTAssertEqual(full.outputSize, CGSize(width: 3_840, height: 2_160))
        XCTAssertTrue(full.sourceRect.isEmpty)
    }

    private func rgba(in image: CGImage, x: Int, y: Int) throws -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &bytes,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let offset = ((min(max(y, 0), image.height - 1) * image.width) + min(max(x, 0), image.width - 1)) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
    }
}
