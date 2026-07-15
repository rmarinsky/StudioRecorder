import CoreGraphics
import Foundation

enum CaptureCanvasPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case fullHD
    case verticalHD
    case widescreen16x10
    case squareHD

    var id: String { rawValue }

    var pixelSize: CGSize {
        switch self {
        case .fullHD: CGSize(width: 1_920, height: 1_080)
        case .verticalHD: CGSize(width: 1_080, height: 1_920)
        case .widescreen16x10: CGSize(width: 1_920, height: 1_200)
        case .squareHD: CGSize(width: 1_080, height: 1_080)
        }
    }

    var label: String {
        switch self {
        case .fullHD: "Full HD · 16:9"
        case .verticalHD: "Vertical · 9:16"
        case .widescreen16x10: "Wide · 16:10"
        case .squareHD: "Square · 1:1"
        }
    }
}

struct CaptureCanvasSnapshot: Codable, Equatable, Sendable {
    var preset: CaptureCanvasPreset?
    var width: Int
    var height: Int

    init(preset: CaptureCanvasPreset = .fullHD) {
        self.preset = preset
        width = Int(preset.pixelSize.width)
        height = Int(preset.pixelSize.height)
    }

    init(width: Int, height: Int) {
        preset = nil
        self.width = width
        self.height = height
    }

    var pixelSize: CGSize { CGSize(width: width, height: height) }
    var aspectRatio: CGFloat { CGFloat(width) / CGFloat(height) }

    func validated() -> CaptureCanvasSnapshot {
        var result = CaptureCanvasSnapshot(
            width: min(max(width, 320), 7_680),
            height: min(max(height, 320), 7_680)
        )
        result.preset = preset
        return result
    }
}

enum ScreenFramingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case fullDisplay
    case fixedRegion
    case followCursor

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fullDisplay: "Full Display"
        case .fixedRegion: "Fixed Region"
        case .followCursor: "Follow Cursor"
        }
    }
}

struct ScreenFramingSnapshot: Codable, Equatable, Sendable {
    var mode: ScreenFramingMode
    var centerX: CGFloat
    var centerY: CGFloat
    var scale: CGFloat

    init(
        mode: ScreenFramingMode = .fullDisplay,
        centerX: CGFloat = 0.5,
        centerY: CGFloat = 0.5,
        scale: CGFloat = 1
    ) {
        self.mode = mode
        self.centerX = centerX
        self.centerY = centerY
        self.scale = scale
    }

    func validated() -> ScreenFramingSnapshot {
        ScreenFramingSnapshot(
            mode: mode,
            centerX: min(max(centerX, 0), 1),
            centerY: min(max(centerY, 0), 1),
            scale: min(max(scale, 0.15), 1)
        )
    }
}

enum SourceShape: String, Codable, CaseIterable, Identifiable, Sendable {
    case rectangle
    case roundedRectangle
    case circle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rectangle: "Rectangle"
        case .roundedRectangle: "Rounded"
        case .circle: "Circle"
        }
    }
}

struct SourcePlacementSnapshot: Codable, Equatable, Sendable {
    var centerX: CGFloat
    var centerY: CGFloat
    var width: CGFloat
    var height: CGFloat
    var shape: SourceShape
    var cornerRadius: CGFloat
    var isVisible: Bool
    var isMirrored: Bool

    init(
        centerX: CGFloat,
        centerY: CGFloat,
        width: CGFloat,
        height: CGFloat? = nil,
        shape: SourceShape,
        cornerRadius: CGFloat = 0,
        isVisible: Bool = true,
        isMirrored: Bool = false
    ) {
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height ?? width
        self.shape = shape
        self.cornerRadius = cornerRadius
        self.isVisible = isVisible
        self.isMirrored = isMirrored
    }

    func validated() -> SourcePlacementSnapshot {
        let validatedWidth = min(max(width, 0.08), 1)
        let validatedHeight = min(max(height, 0.08), 1)

        return SourcePlacementSnapshot(
            centerX: min(max(centerX, validatedWidth / 2), 1 - validatedWidth / 2),
            centerY: min(max(centerY, validatedHeight / 2), 1 - validatedHeight / 2),
            width: validatedWidth,
            height: validatedHeight,
            shape: shape,
            cornerRadius: min(max(cornerRadius, 0), 0.5),
            isVisible: isVisible,
            isMirrored: isMirrored
        )
    }
}

struct CursorTreatmentSnapshot: Codable, Equatable, Sendable {
    var scale: CGFloat
    var highlightsClicks: Bool

    init(scale: CGFloat = 1.5, highlightsClicks: Bool = true) {
        self.scale = scale
        self.highlightsClicks = highlightsClicks
    }

    func validated() -> CursorTreatmentSnapshot {
        CursorTreatmentSnapshot(
            scale: min(max(scale, 1), 4),
            highlightsClicks: highlightsClicks
        )
    }
}

struct CapturePresentationSnapshot: Codable, Equatable, Sendable {
    var canvas: CaptureCanvasSnapshot
    var framing: ScreenFramingSnapshot
    var screen: SourcePlacementSnapshot
    var camera: SourcePlacementSnapshot
    var cursor: CursorTreatmentSnapshot

    static let `default` = CapturePresentationSnapshot(
        canvas: CaptureCanvasSnapshot(),
        framing: ScreenFramingSnapshot(),
        screen: SourcePlacementSnapshot(
            centerX: 0.5,
            centerY: 0.5,
            width: 1,
            shape: .rectangle
        ),
        camera: SourcePlacementSnapshot(
            centerX: 0.86,
            centerY: 0.82,
            width: 0.22,
            shape: .circle,
            isMirrored: true
        ),
        cursor: CursorTreatmentSnapshot()
    )

    func validated() -> CapturePresentationSnapshot {
        CapturePresentationSnapshot(
            canvas: canvas.validated(),
            framing: framing.validated(),
            screen: screen.validated(),
            camera: camera.validated(),
            cursor: cursor.validated()
        )
    }
}

enum CaptureGeometryPlanner {
    struct StreamGeometry: Equatable, Sendable {
        let sourceRect: CGRect
        let outputSize: CGSize
    }

    static func streamGeometry(
        displaySize: CGSize,
        pointPixelScale: CGFloat,
        presentation: CapturePresentationSnapshot
    ) -> StreamGeometry {
        let presentation = presentation.validated()
        guard presentation.framing.mode == .fixedRegion else {
            return StreamGeometry(
                sourceRect: .zero,
                outputSize: CGSize(
                    width: displaySize.width * pointPixelScale,
                    height: displaySize.height * pointPixelScale
                )
            )
        }
        return StreamGeometry(
            sourceRect: sourceRect(
                displaySize: displaySize,
                canvasSize: presentation.canvas.pixelSize,
                framing: presentation.framing
            ),
            outputSize: presentation.canvas.pixelSize
        )
    }

    static func sourceRect(
        displaySize: CGSize,
        canvasSize: CGSize,
        framing: ScreenFramingSnapshot
    ) -> CGRect {
        guard displaySize.width > 0,
              displaySize.height > 0,
              canvasSize.width > 0,
              canvasSize.height > 0 else { return .zero }

        let framing = framing.validated()
        let canvasAspect = canvasSize.width / canvasSize.height
        let displayAspect = displaySize.width / displaySize.height
        let maximumSize: CGSize
        if displayAspect >= canvasAspect {
            maximumSize = CGSize(width: displaySize.height * canvasAspect, height: displaySize.height)
        } else {
            maximumSize = CGSize(width: displaySize.width, height: displaySize.width / canvasAspect)
        }
        let size = CGSize(
            width: maximumSize.width * framing.scale,
            height: maximumSize.height * framing.scale
        )
        let desiredOrigin = CGPoint(
            x: displaySize.width * framing.centerX - size.width / 2,
            y: displaySize.height * framing.centerY - size.height / 2
        )
        return CGRect(
            x: min(max(desiredOrigin.x, 0), displaySize.width - size.width),
            y: min(max(desiredOrigin.y, 0), displaySize.height - size.height),
            width: size.width,
            height: size.height
        )
    }
}
