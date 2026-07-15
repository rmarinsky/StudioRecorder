import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation

struct ProgramCursorState: Equatable, Sendable {
    let normalizedX: CGFloat
    let normalizedY: CGFloat
    let isPrimaryButtonDown: Bool

    init(normalizedX: CGFloat, normalizedY: CGFloat, isPrimaryButtonDown: Bool) {
        self.normalizedX = min(max(normalizedX, 0), 1)
        self.normalizedY = min(max(normalizedY, 0), 1)
        self.isPrimaryButtonDown = isPrimaryButtonDown
    }
}

final class ProgramFrameCompositor: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let cameraBackgroundProcessor: CameraBackgroundProcessor

    init(personQuality: CameraBackgroundProcessor.PersonQuality) {
        cameraBackgroundProcessor = CameraBackgroundProcessor(personQuality: personQuality)
    }

    func render(
        screen: CIImage?,
        camera: CIImage?,
        screenTransform: CGAffineTransform = .identity,
        cameraTransform: CGAffineTransform = .identity,
        presentation: CapturePresentationSnapshot,
        screenFraming: ScreenFramingSnapshot? = nil,
        cursor: ProgramCursorState? = nil,
        to output: CVPixelBuffer
    ) {
        let presentation = presentation.validated()
        let canvas = CGRect(origin: .zero, size: presentation.canvas.pixelSize)
        var result = CIImage(color: CIColor(red: 0.04, green: 0.04, blue: 0.04)).cropped(to: canvas)
        if presentation.screen.isVisible, let screen {
            result = compose(
                screen,
                transform: screenTransform,
                placement: presentation.screen,
                framing: screenFraming,
                cursor: cursor,
                cursorTreatment: presentation.cursor,
                canvasSize: presentation.canvas.pixelSize,
                canvas: canvas,
                over: result
            )
        }
        if presentation.camera.isVisible, let camera {
            result = compose(
                cameraBackgroundProcessor.process(camera, background: presentation.resolvedCameraBackground),
                transform: cameraTransform,
                placement: presentation.camera,
                framing: nil,
                cursor: nil,
                cursorTreatment: presentation.cursor,
                canvasSize: presentation.canvas.pixelSize,
                canvas: canvas,
                over: result
            )
        }
        context.render(result, to: output, bounds: canvas, colorSpace: CGColorSpaceCreateDeviceRGB())
    }

    private func compose(
        _ source: CIImage,
        transform: CGAffineTransform,
        placement: SourcePlacementSnapshot,
        framing: ScreenFramingSnapshot?,
        cursor: ProgramCursorState?,
        cursorTreatment: CursorTreatmentSnapshot,
        canvasSize: CGSize,
        canvas: CGRect,
        over background: CIImage
    ) -> CIImage {
        var oriented = source.transformed(by: transform)
        oriented = oriented.transformed(by: CGAffineTransform(
            translationX: -oriented.extent.minX,
            y: -oriented.extent.minY
        ))
        var cursorPoint = cursor.map {
            CGPoint(
                x: oriented.extent.width * $0.normalizedX,
                y: oriented.extent.height * (1 - $0.normalizedY)
            )
        }
        if let framing {
            let rect = cropRect(oriented, canvasSize: canvasSize, framing: framing)
            oriented = oriented.cropped(to: rect).transformed(by: CGAffineTransform(
                translationX: -rect.minX,
                y: -rect.minY
            ))
            cursorPoint = cursorPoint.map { CGPoint(x: $0.x - rect.minX, y: $0.y - rect.minY) }
        }
        let target = CGRect(
            x: canvas.width * placement.centerX - canvas.width * placement.width / 2,
            y: canvas.height * (1 - placement.centerY) - canvas.height * placement.height / 2,
            width: canvas.width * placement.width,
            height: canvas.height * placement.height
        )
        let scale = max(target.width / oriented.extent.width, target.height / oriented.extent.height)
        var foreground = oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let translation = CGPoint(
            x: target.midX - foreground.extent.midX,
            y: target.midY - foreground.extent.midY
        )
        foreground = foreground.transformed(by: CGAffineTransform(
            translationX: translation.x,
            y: translation.y
        ))
        if let cursor,
           let cursorPoint,
           let cursorImage = cursorImage(
               treatment: cursorTreatment,
               isPrimaryButtonDown: cursor.isPrimaryButtonDown,
               at: CGPoint(
                   x: cursorPoint.x * scale + translation.x,
                   y: cursorPoint.y * scale + translation.y
               )
           ) {
            foreground = cursorImage.composited(over: foreground)
        }
        foreground = foreground.cropped(to: target)
        if placement.isMirrored {
            foreground = foreground.transformed(by: CGAffineTransform(
                translationX: target.midX,
                y: 0
            ).scaledBy(x: -1, y: 1).translatedBy(x: -target.midX, y: 0))
        }
        guard placement.shape != .rectangle else { return foreground.composited(over: background) }

        let mask: CIImage?
        if placement.shape == .circle {
            let ellipse = CIFilter.radialGradient()
            ellipse.center = .zero
            ellipse.radius0 = 0.499
            ellipse.radius1 = 0.501
            ellipse.color0 = .white
            ellipse.color1 = .clear
            mask = ellipse.outputImage?
                .transformed(by: CGAffineTransform(scaleX: target.width, y: target.height))
                .transformed(by: CGAffineTransform(translationX: target.midX, y: target.midY))
                .cropped(to: target)
        } else {
            let roundedRectangle = CIFilter.roundedRectangleGenerator()
            roundedRectangle.extent = target
            roundedRectangle.radius = Float(max(1, placement.effectiveCornerRadius * min(target.width, target.height)))
            roundedRectangle.color = .white
            mask = roundedRectangle.outputImage
        }
        guard let mask else { return foreground.composited(over: background) }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = foreground.composited(over: background)
        blend.backgroundImage = background
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: canvas) ?? foreground.composited(over: background)
    }

    private func cropRect(
        _ image: CIImage,
        canvasSize: CGSize,
        framing: ScreenFramingSnapshot
    ) -> CGRect {
        let extent = image.extent
        guard extent.width > 0,
              extent.height > 0,
              canvasSize.width > 0,
              canvasSize.height > 0 else { return extent }
        let canvasAspect = canvasSize.width / canvasSize.height
        let imageAspect = extent.width / extent.height
        let maximumSize: CGSize
        if imageAspect >= canvasAspect {
            maximumSize = CGSize(width: extent.height * canvasAspect, height: extent.height)
        } else {
            maximumSize = CGSize(width: extent.width, height: extent.width / canvasAspect)
        }
        let cropSize = CGSize(
            width: maximumSize.width * framing.scale,
            height: maximumSize.height * framing.scale
        )
        let desiredOrigin = CGPoint(
            x: extent.width * framing.centerX - cropSize.width / 2,
            y: extent.height * (1 - framing.centerY) - cropSize.height / 2
        )
        return CGRect(
            x: min(max(desiredOrigin.x, 0), extent.width - cropSize.width),
            y: min(max(desiredOrigin.y, 0), extent.height - cropSize.height),
            width: cropSize.width,
            height: cropSize.height
        )
    }

    private func cursorImage(
        treatment: CursorTreatmentSnapshot,
        isPrimaryButtonDown: Bool,
        at point: CGPoint
    ) -> CIImage? {
        let cursorScale = treatment.validated().scale
        let side = max(48, Int((48 * cursorScale).rounded(.up)))
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let scale = cursorScale
        let hotspot = CGPoint(x: 12 * scale, y: CGFloat(side) - 12 * scale)
        context.setLineJoin(.round)
        context.setLineCap(.round)

        if treatment.highlightsClicks, isPrimaryButtonDown {
            let radius = 10 * scale
            context.setStrokeColor(CGColor(red: 1, green: 0.20, blue: 0.16, alpha: 0.95))
            context.setLineWidth(3 * scale)
            context.strokeEllipse(in: CGRect(
                x: hotspot.x - radius,
                y: hotspot.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }

        let path = CGMutablePath()
        path.move(to: hotspot)
        path.addLine(to: CGPoint(x: hotspot.x + 2 * scale, y: hotspot.y - 22 * scale))
        path.addLine(to: CGPoint(x: hotspot.x + 7 * scale, y: hotspot.y - 17 * scale))
        path.addLine(to: CGPoint(x: hotspot.x + 12 * scale, y: hotspot.y - 27 * scale))
        path.addLine(to: CGPoint(x: hotspot.x + 17 * scale, y: hotspot.y - 24 * scale))
        path.addLine(to: CGPoint(x: hotspot.x + 12 * scale, y: hotspot.y - 15 * scale))
        path.addLine(to: CGPoint(x: hotspot.x + 21 * scale, y: hotspot.y - 15 * scale))
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(CGColor(gray: 0.05, alpha: 1))
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(2.5 * scale)
        context.drawPath(using: .fillStroke)

        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image).transformed(by: CGAffineTransform(
            translationX: point.x - hotspot.x,
            y: point.y - hotspot.y
        ))
    }
}
