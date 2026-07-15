import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation

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
        canvasSize: CGSize,
        canvas: CGRect,
        over background: CIImage
    ) -> CIImage {
        var oriented = source.transformed(by: transform)
        oriented = oriented.transformed(by: CGAffineTransform(
            translationX: -oriented.extent.minX,
            y: -oriented.extent.minY
        ))
        if let framing {
            oriented = crop(oriented, canvasSize: canvasSize, framing: framing)
        }
        let target = CGRect(
            x: canvas.width * placement.centerX - canvas.width * placement.width / 2,
            y: canvas.height * (1 - placement.centerY) - canvas.height * placement.height / 2,
            width: canvas.width * placement.width,
            height: canvas.height * placement.height
        )
        let scale = max(target.width / oriented.extent.width, target.height / oriented.extent.height)
        var foreground = oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        foreground = foreground.transformed(by: CGAffineTransform(
            translationX: target.midX - foreground.extent.midX,
            y: target.midY - foreground.extent.midY
        )).cropped(to: target)
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
            roundedRectangle.radius = Float(max(4, placement.cornerRadius * min(target.width, target.height)))
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

    private func crop(
        _ image: CIImage,
        canvasSize: CGSize,
        framing: ScreenFramingSnapshot
    ) -> CIImage {
        let extent = image.extent
        guard extent.width > 0,
              extent.height > 0,
              canvasSize.width > 0,
              canvasSize.height > 0 else { return image }
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
        let cropRect = CGRect(
            x: min(max(desiredOrigin.x, 0), extent.width - cropSize.width),
            y: min(max(desiredOrigin.y, 0), extent.height - cropSize.height),
            width: cropSize.width,
            height: cropSize.height
        )
        return image.cropped(to: cropRect).transformed(by: CGAffineTransform(
            translationX: -cropRect.minX,
            y: -cropRect.minY
        ))
    }
}
