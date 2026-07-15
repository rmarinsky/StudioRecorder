import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum LiveSceneSnapshotError: LocalizedError, Equatable {
    case outputBufferUnavailable
    case renderedImageUnavailable
    case destinationCreationFailed
    case destinationWriteFailed

    var errorDescription: String? {
        switch self {
        case .outputBufferUnavailable:
            "Studio Recorder could not prepare the screenshot canvas."
        case .renderedImageUnavailable:
            "Studio Recorder could not render the current stage."
        case .destinationCreationFailed:
            "Studio Recorder could not create the screenshot file."
        case .destinationWriteFailed:
            "Studio Recorder could not finish writing the screenshot."
        }
    }
}

struct LiveSceneSnapshotSources: @unchecked Sendable {
    let screen: CGImage
    let camera: CVPixelBuffer?
}

actor LiveSceneSnapshotExporter {
    private let compositor = ProgramFrameCompositor(personQuality: .export)
    private let imageContext = CIContext(options: [.cacheIntermediates: false])

    func export(
        sources: LiveSceneSnapshotSources,
        presentation: CapturePresentationSnapshot,
        screenFraming: ScreenFramingSnapshot?,
        cursor: ProgramCursorState?,
        to destinationURL: URL
    ) throws {
        let presentation = presentation.validated()
        guard let output = makeOutputBuffer(size: presentation.canvas.pixelSize) else {
            throw LiveSceneSnapshotError.outputBufferUnavailable
        }
        compositor.render(
            screen: CIImage(cgImage: sources.screen),
            camera: sources.camera.map(CIImage.init(cvPixelBuffer:)),
            presentation: presentation,
            screenFraming: screenFraming,
            cursor: cursor,
            to: output
        )
        let canvas = CGRect(origin: .zero, size: presentation.canvas.pixelSize)
        guard let rendered = imageContext.createCGImage(CIImage(cvPixelBuffer: output), from: canvas) else {
            throw LiveSceneSnapshotError.renderedImageUnavailable
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw LiveSceneSnapshotError.destinationCreationFailed
        }
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw LiveSceneSnapshotError.destinationWriteFailed
        }
        do {
            try Data(referencing: data).write(to: destinationURL, options: .atomic)
        } catch {
            throw LiveSceneSnapshotError.destinationWriteFailed
        }
    }

    private func makeOutputBuffer(size: CGSize) -> CVPixelBuffer? {
        guard size.width > 0, size.height > 0 else { return nil }
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        return status == kCVReturnSuccess ? buffer : nil
    }
}
