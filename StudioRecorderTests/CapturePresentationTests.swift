import CoreGraphics
import CoreImage
import XCTest
@testable import StudioRecorder

final class CapturePresentationTests: XCTestCase {
    func testPNGImporterCopiesAndPlacesDroppedImageAtItsDropPoint() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let importedDirectory = directory.appending(path: "Imported")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appending(path: "logo.png")
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
        try CIContext().writePNGRepresentation(
            of: image,
            to: sourceURL,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        let overlay = try ImageOverlayImporter.importPNG(
            from: sourceURL,
            canvas: CaptureCanvasSnapshot(preset: .fullHD),
            center: CGPoint(x: 0.25, y: 0.75),
            destinationDirectory: importedDirectory
        )

        XCTAssertEqual(overlay.name, "logo")
        XCTAssertEqual(overlay.placement.centerX, 0.25, accuracy: 0.001)
        XCTAssertEqual(overlay.placement.centerY, 0.75, accuracy: 0.001)
        XCTAssertEqual(overlay.placement.width, 0.2, accuracy: 0.001)
        XCTAssertEqual(overlay.placement.height, 0.178, accuracy: 0.001)
        XCTAssertTrue(FileManager.default.fileExists(atPath: overlay.filePath))
    }

    func testPNGImporterRejectsOtherFileTypes() {
        XCTAssertThrowsError(try ImageOverlayImporter.importPNG(
            from: URL(fileURLWithPath: "/tmp/logo.jpg"),
            canvas: CaptureCanvasSnapshot(preset: .fullHD)
        )) { error in
            guard case ImageOverlayImportError.notPNG = error else {
                return XCTFail("Expected a clear PNG-only validation error")
            }
        }
    }

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
        XCTAssertTrue(decoded.resolvedImageOverlays.isEmpty)
        XCTAssertNil(decoded.screen.shadow)
        XCTAssertEqual(decoded.resolvedName, "Scene 1")
    }

    func testProgramCompositorRendersPNGOverlayAndItsShadow() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let overlayURL = directory.appending(path: "logo.png")
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(
            to: CGRect(x: 0, y: 0, width: 20, height: 20)
        )
        try CIContext().writePNGRepresentation(
            of: red,
            to: overlayURL,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        var presentation = CapturePresentationSnapshot.default
        presentation.canvas = CaptureCanvasSnapshot(width: 320, height: 320)
        presentation.camera.isVisible = false
        presentation.imageOverlays = [ImageOverlaySnapshot(
            name: "Logo",
            filePath: overlayURL.path,
            placement: SourcePlacementSnapshot(
                centerX: 0.4,
                centerY: 0.5,
                width: 0.2,
                height: 0.2,
                shape: .rectangle,
                shadow: SourceShadowSnapshot(opacity: 1, radius: 0, offsetX: 0.12, offsetY: 0)
            )
        )]
        let output = try pixelBuffer(width: 320, height: 320)
        ProgramFrameCompositor(personQuality: .export).render(
            screen: CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(
                to: CGRect(x: 0, y: 0, width: 320, height: 320)
            ),
            camera: nil,
            presentation: presentation,
            to: output
        )
        let rendered = try XCTUnwrap(CIContext().createCGImage(
            CIImage(cvPixelBuffer: output),
            from: CGRect(x: 0, y: 0, width: 320, height: 320)
        ))

        let logo = try rgba(in: rendered, x: 128, y: 160)
        let shadow = try rgba(in: rendered, x: 180, y: 160)
        let background = try rgba(in: rendered, x: 250, y: 160)
        XCTAssertGreaterThan(logo.red, 200)
        XCTAssertLessThan(shadow.red, 30)
        XCTAssertLessThan(shadow.blue, 30)
        XCTAssertGreaterThan(background.blue, 200)
    }

    func testLegacyCursorTreatmentKeepsShortcutDisplayOff() throws {
        let data = Data(#"{"scale":1.5,"highlightsClicks":true}"#.utf8)
        let decoded = try JSONDecoder().decode(CursorTreatmentSnapshot.self, from: data)

        XCTAssertFalse(decoded.resolvedShowsShortcutKeys)
        XCTAssertFalse(decoded.validated().resolvedShowsShortcutKeys)
    }

    func testLegacyCameraBackgroundDefaultsToAdaptivePerformance() throws {
        let legacy = """
        {
          "mode": "person",
          "keyColor": "green",
          "tolerance": 0.28,
          "softness": 0.12,
          "spillSuppression": 0.55
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(CameraBackgroundSnapshot.self, from: legacy)

        XCTAssertEqual(decoded.resolvedPerformanceProfile, .auto)
    }

    func testCameraBackgroundPerformanceProfileRoundTrips() throws {
        let background = CameraBackgroundSnapshot(mode: .person, performanceProfile: .performance)

        let decoded = try JSONDecoder().decode(
            CameraBackgroundSnapshot.self,
            from: JSONEncoder().encode(background)
        )

        XCTAssertEqual(decoded.resolvedPerformanceProfile, .performance)
    }

    func testCameraBackgroundBlurSettingsRoundTripAndClamp() throws {
        let background = CameraBackgroundSnapshot(mode: .blur, blurRadius: 120).validated()
        let decoded = try JSONDecoder().decode(
            CameraBackgroundSnapshot.self,
            from: JSONEncoder().encode(background)
        )

        XCTAssertEqual(decoded.mode, .blur)
        XCTAssertEqual(decoded.resolvedBlurRadius, 80)
    }

    func testCameraBackgroundBlurKeepsTheMaskedForegroundSharp() throws {
        let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
        let left = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(
            to: CGRect(x: 0, y: 0, width: 32, height: 64)
        )
        let right = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(
            to: CGRect(x: 32, y: 0, width: 32, height: 64)
        )
        let source = right.composited(over: left).cropped(to: extent)
        let foregroundMask = CIImage(color: .white).cropped(
            to: CGRect(x: 28, y: 20, width: 8, height: 24)
        ).composited(over: CIImage(color: .black).cropped(to: extent))
        let processed = try XCTUnwrap(CameraBackgroundProcessor.blurringBackground(
            in: source,
            withPersonMask: foregroundMask,
            radius: 12
        ))
        let cgImage = try XCTUnwrap(CIContext().createCGImage(processed, from: extent))

        let maskedBlack = try rgba(in: cgImage, x: 30, y: 32)
        let blurredBlack = try rgba(in: cgImage, x: 24, y: 32)
        XCTAssertLessThan(maskedBlack.red, 20)
        XCTAssertGreaterThan(blurredBlack.red, maskedBlack.red + 20)
    }

    func testCameraBackgroundBlurStrengthStaysProportionalAcrossPreviewAndOutput() {
        let previewRadius = CameraBackgroundProcessor.scaledBlurRadius(
            24,
            for: CGRect(x: 0, y: 0, width: 960, height: 540)
        )
        let outputRadius = CameraBackgroundProcessor.scaledBlurRadius(
            24,
            for: CGRect(x: 0, y: 0, width: 3_840, height: 2_160)
        )

        XCTAssertEqual(previewRadius, 12, accuracy: 0.001)
        XCTAssertEqual(outputRadius, 48, accuracy: 0.001)
        XCTAssertEqual(previewRadius / 540, outputRadius / 2_160, accuracy: 0.0001)
    }

    func testLiveCameraBlurBoundsFourKWorkWithoutChangingOutputExtent() throws {
        let fourKExtent = CGRect(x: 10, y: 20, width: 3_840, height: 2_160)
        XCTAssertEqual(
            CameraBackgroundProcessor.blurWorkingScale(for: fourKExtent, maximumDimension: 960),
            0.25,
            accuracy: 0.001
        )

        let extent = CGRect(x: 10, y: 20, width: 384, height: 216)
        let source = CIImage(color: .white).cropped(to: extent)
        let mask = CIImage(color: .black).cropped(to: extent)
        let processed = try XCTUnwrap(CameraBackgroundProcessor.blurringBackground(
            in: source,
            withPersonMask: mask,
            radius: 4.8,
            maximumDimension: 96
        ))

        XCTAssertEqual(processed.extent, extent)
    }

    func testAutoCameraBackgroundPlanDegradesBeforeCaptureStalls() {
        let normal = CameraBackgroundProcessingPlan.live(
            profile: .auto,
            averageProcessingDuration: 0.02
        )
        let overloaded = CameraBackgroundProcessingPlan.live(
            profile: .auto,
            averageProcessingDuration: 0.08
        )
        let stillDegraded = CameraBackgroundProcessingPlan.live(
            profile: .auto,
            averageProcessingDuration: 0.04,
            autoIsDegraded: true
        )
        let recovered = CameraBackgroundProcessingPlan.live(
            profile: .auto,
            averageProcessingDuration: 0.02,
            autoIsDegraded: true
        )

        XCTAssertEqual(normal.effectiveProfile, .auto)
        XCTAssertEqual(normal.maximumInputDimension, 384)
        XCTAssertEqual(overloaded.effectiveProfile, .performance)
        XCTAssertEqual(overloaded.maximumInputDimension, 256)
        XCTAssertGreaterThan(overloaded.minimumMaskInterval, normal.minimumMaskInterval)
        XCTAssertEqual(stillDegraded.effectiveProfile, .performance)
        XCTAssertEqual(recovered.effectiveProfile, .auto)
    }

    func testExplicitCameraBackgroundProfilesRemainStableUnderLoad() {
        let quality = CameraBackgroundProcessingPlan.live(
            profile: .quality,
            averageProcessingDuration: 0.2
        )
        let performance = CameraBackgroundProcessingPlan.live(
            profile: .performance,
            averageProcessingDuration: 0
        )

        XCTAssertEqual(quality.effectiveProfile, .quality)
        XCTAssertEqual(quality.maximumInputDimension, 512)
        XCTAssertEqual(performance.effectiveProfile, .performance)
        XCTAssertEqual(performance.maximumInputDimension, 256)
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

    func testFollowCursorViewportUsesTheResizedScreenLayerAspectAtTheDisplayEdge() {
        let region = CaptureGeometryPlanner.sourceRect(
            displaySize: CGSize(width: 3_840, height: 2_160),
            canvasSize: CGSize(width: 2_700, height: 2_160),
            framing: ScreenFramingSnapshot(
                mode: .followCursor,
                centerX: 0,
                centerY: 0.5,
                scale: 0.55
            )
        )

        XCTAssertEqual(region.width / region.height, 2_700.0 / 2_160.0, accuracy: 0.001)
        XCTAssertEqual(region.minX, 0, accuracy: 0.001)
        XCTAssertEqual(region.midY, 1_080, accuracy: 0.001)
    }

    func testManualZoomTargetsTheCursorInsideTheSelectedDisplay() {
        let framing = ManualZoomPlanner.zoomedFraming(
            cursor: CGPoint(x: 750, y: 500),
            displayFrame: CGRect(x: 500, y: 100, width: 1_000, height: 800),
            scale: 0.5
        )

        XCTAssertEqual(framing.mode, .fixedRegion)
        XCTAssertEqual(framing.centerX, 0.25, accuracy: 0.001)
        XCTAssertEqual(framing.centerY, 0.5, accuracy: 0.001)
        XCTAssertEqual(framing.scale, 0.5, accuracy: 0.001)
    }

    func testManualZoomUsesTheLastExternalPointerWhenTriggeredFromStudio() {
        let target = ManualZoomPlanner.targetPoint(
            currentPointer: CGPoint(x: 1_400, y: 700),
            isOverStudio: true,
            lastExternalPointer: CGPoint(x: 720, y: 440),
            displayFrame: CGRect(x: 500, y: 100, width: 1_000, height: 800)
        )

        XCTAssertEqual(target, CGPoint(x: 720, y: 440))
    }

    func testManualZoomFallsBackToTheSelectedDisplayCenter() {
        let target = ManualZoomPlanner.targetPoint(
            currentPointer: CGPoint(x: 1_400, y: 700),
            isOverStudio: true,
            lastExternalPointer: CGPoint(x: 200, y: 200),
            displayFrame: CGRect(x: 500, y: 100, width: 1_000, height: 800)
        )

        XCTAssertEqual(target, CGPoint(x: 1_000, y: 500))
    }

    func testManualZoomResetReturnsToTheFullDisplay() {
        let reset = ManualZoomPlanner.resetFraming(from: ScreenFramingSnapshot(
            mode: .fixedRegion,
            centerX: 0.2,
            centerY: 0.8,
            scale: 0.4
        ))

        XCTAssertEqual(reset.mode, .fullDisplay)
        XCTAssertEqual(reset.scale, 1)
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

    func testCircleCameraValidatesToASquareInCanvasPixels() {
        var presentation = CapturePresentationSnapshot.default
        presentation.camera = SourcePlacementSnapshot(
            centerX: 0.5,
            centerY: 0.5,
            width: 0.4,
            height: 0.2,
            shape: .circle
        )

        let validated = presentation.validated()
        let canvas = validated.canvas.pixelSize

        XCTAssertEqual(
            validated.camera.width * canvas.width,
            validated.camera.height * canvas.height,
            accuracy: 0.001
        )
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

    private func pixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer),
            kCVReturnSuccess
        )
        return try XCTUnwrap(buffer)
    }
}
