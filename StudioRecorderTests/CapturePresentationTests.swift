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
        XCTAssertEqual(CaptureCanvasPreset.ultraHD.pixelSize, CGSize(width: 3_840, height: 2_160))
        XCTAssertEqual(CaptureCanvasPreset.verticalHD.pixelSize, CGSize(width: 1_080, height: 1_920))
        XCTAssertEqual(CaptureCanvasPreset.vertical4K.pixelSize, CGSize(width: 2_160, height: 3_840))
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

    func testBottomRightResizeKeepsTheOppositeCornerAnchored() {
        let placement = SourcePlacementSnapshot(
            centerX: 0.5,
            centerY: 0.5,
            width: 0.4,
            height: 0.4,
            shape: .rectangle
        )

        let resized = SourcePlacementManipulator.resized(
            placement,
            from: .bottomRight,
            translation: CGSize(width: 200, height: 100),
            canvasSize: CGSize(width: 1_000, height: 500)
        )

        XCTAssertEqual(resized.centerX, 0.6, accuracy: 0.001)
        XCTAssertEqual(resized.centerY, 0.6, accuracy: 0.001)
        XCTAssertEqual(resized.width, 0.6, accuracy: 0.001)
        XCTAssertEqual(resized.height, 0.6, accuracy: 0.001)
    }

    func testCornerResizeClampsToTheCanvasWithoutMovingTheOppositeCorner() {
        let placement = SourcePlacementSnapshot(
            centerX: 0.5,
            centerY: 0.5,
            width: 0.4,
            height: 0.4,
            shape: .rectangle
        )

        let resized = SourcePlacementManipulator.resized(
            placement,
            from: .topLeft,
            translation: CGSize(width: -800, height: -400),
            canvasSize: CGSize(width: 1_000, height: 500)
        )

        XCTAssertEqual(resized.centerX, 0.35, accuracy: 0.001)
        XCTAssertEqual(resized.centerY, 0.35, accuracy: 0.001)
        XCTAssertEqual(resized.width, 0.7, accuracy: 0.001)
        XCTAssertEqual(resized.height, 0.7, accuracy: 0.001)
    }

    func testCornerResizeCannotCrossTheOppositeCorner() {
        let placement = SourcePlacementSnapshot(
            centerX: 0.5,
            centerY: 0.5,
            width: 0.4,
            height: 0.4,
            shape: .rectangle
        )

        let resized = SourcePlacementManipulator.resized(
            placement,
            from: .bottomRight,
            translation: CGSize(width: -900, height: -450),
            canvasSize: CGSize(width: 1_000, height: 500)
        )

        XCTAssertEqual(resized.centerX, 0.34, accuracy: 0.001)
        XCTAssertEqual(resized.centerY, 0.34, accuracy: 0.001)
        XCTAssertEqual(resized.width, 0.08, accuracy: 0.001)
        XCTAssertEqual(resized.height, 0.08, accuracy: 0.001)
    }

    func testMoveStaysInsideTheCanvasContinuously() {
        let placement = SourcePlacementSnapshot(
            centerX: 0.8,
            centerY: 0.2,
            width: 0.2,
            height: 0.3,
            shape: .roundedRectangle
        )

        let moved = SourcePlacementManipulator.moved(
            placement,
            translation: CGSize(width: 900, height: -400),
            canvasSize: CGSize(width: 1_000, height: 500)
        )

        XCTAssertEqual(moved.centerX, 0.9, accuracy: 0.001)
        XCTAssertEqual(moved.centerY, 0.15, accuracy: 0.001)
    }

    func testFullCanvasSourceCannotMoveOutsideTheCanvas() {
        let moved = SourcePlacementManipulator.moved(
            CapturePresentationSnapshot.default.screen,
            translation: CGSize(width: 500, height: 300),
            canvasSize: CGSize(width: 1_000, height: 500)
        )

        XCTAssertEqual(moved.centerX, 0.5, accuracy: 0.001)
        XCTAssertEqual(moved.centerY, 0.5, accuracy: 0.001)
    }

    func testResizeHandleHitTargetStaysInsideTheCanvas() {
        let topLeft = SourcePlacementManipulator.resizeHandlePosition(
            .topLeft,
            sourceFrame: CGRect(x: 0, y: 0, width: 1_000, height: 500),
            canvasSize: CGSize(width: 1_000, height: 500),
            hitTargetSize: 28
        )
        let bottomRight = SourcePlacementManipulator.resizeHandlePosition(
            .bottomRight,
            sourceFrame: CGRect(x: 0, y: 0, width: 1_000, height: 500),
            canvasSize: CGSize(width: 1_000, height: 500),
            hitTargetSize: 28
        )

        XCTAssertEqual(topLeft, CGPoint(x: 14, y: 14))
        XCTAssertEqual(bottomRight, CGPoint(x: 986, y: 486))
    }

    func testInsetResizeHandlePreservesItsEdgeOffsetWhileDragging() {
        let movedTopLeft = SourcePlacementManipulator.resizeHandlePosition(
            .topLeft,
            sourceFrame: CGRect(x: 10, y: 8, width: 990, height: 492),
            canvasSize: CGSize(width: 1_000, height: 500),
            hitTargetSize: 28,
            anchorSourceFrame: CGRect(x: 0, y: 0, width: 1_000, height: 500)
        )
        let movedBottomRight = SourcePlacementManipulator.resizeHandlePosition(
            .bottomRight,
            sourceFrame: CGRect(x: 0, y: 0, width: 990, height: 492),
            canvasSize: CGSize(width: 1_000, height: 500),
            hitTargetSize: 28,
            anchorSourceFrame: CGRect(x: 0, y: 0, width: 1_000, height: 500)
        )

        XCTAssertEqual(movedTopLeft, CGPoint(x: 24, y: 22))
        XCTAssertEqual(movedBottomRight, CGPoint(x: 976, y: 478))
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
