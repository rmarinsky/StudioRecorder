import CoreImage
import CoreVideo
import Foundation
import Vision

final class CameraBackgroundProcessor: @unchecked Sendable {
    enum PersonQuality: Sendable {
        case live
        case export
    }

    private let lock = NSLock()
    private let request: VNGeneratePersonSegmentationRequest
    private var cachedCube: (settings: CameraBackgroundSnapshot, data: Data)?

    init(personQuality: PersonQuality) {
        request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = personQuality == .live ? .fast : .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    func process(_ image: CIImage, background: CameraBackgroundSnapshot) -> CIImage {
        let background = background.validated()
        switch background.mode {
        case .off:
            return image
        case .person:
            return personForeground(from: image) ?? image
        case .greenScreen:
            return chromaKey(image, settings: background)
        }
    }

    private func personForeground(from image: CIImage) -> CIImage? {
        lock.withLock {
            // Continuity Camera can deliver 4K frames. Vision's live segmentation
            // does not need those pixels, and processing them would stall preview
            // delivery for seconds. Generate the mask from a bounded input and
            // scale only the one-channel mask back to the source extent.
            let normalized = image.transformed(by: CGAffineTransform(
                translationX: -image.extent.minX,
                y: -image.extent.minY
            ))
            let maximumInputDimension: CGFloat = 640
            let inputScale = min(
                1,
                maximumInputDimension / max(normalized.extent.width, normalized.extent.height)
            )
            let requestImage = normalized.transformed(by: CGAffineTransform(
                scaleX: inputScale,
                y: inputScale
            ))
            let handler = VNImageRequestHandler(ciImage: requestImage, options: [:])
            do {
                try handler.perform([request])
                guard let observation = request.results?.first else { return nil }
                let rawMask = CIImage(cvPixelBuffer: observation.pixelBuffer)
                let mask = rawMask
                    .transformed(by: CGAffineTransform(
                        scaleX: image.extent.width / rawMask.extent.width,
                        y: image.extent.height / rawMask.extent.height
                    ))
                    .transformed(by: CGAffineTransform(
                        translationX: image.extent.minX,
                        y: image.extent.minY
                    ))
                    .cropped(to: image.extent)
                let blend = CIFilter(name: "CIBlendWithMask")
                blend?.setValue(image, forKey: kCIInputImageKey)
                blend?.setValue(
                    CIImage(color: .clear).cropped(to: image.extent),
                    forKey: kCIInputBackgroundImageKey
                )
                blend?.setValue(mask, forKey: kCIInputMaskImageKey)
                return blend?.outputImage?.cropped(to: image.extent)
            } catch {
                return nil
            }
        }
    }

    private func chromaKey(_ image: CIImage, settings: CameraBackgroundSnapshot) -> CIImage {
        let cubeData = lock.withLock { () -> Data in
            if let cachedCube, cachedCube.settings == settings {
                return cachedCube.data
            }
            let data = makeColorCube(settings: settings)
            cachedCube = (settings, data)
            return data
        }
        let filter = CIFilter(name: "CIColorCube")
        filter?.setValue(image, forKey: kCIInputImageKey)
        filter?.setValue(32, forKey: "inputCubeDimension")
        filter?.setValue(cubeData, forKey: "inputCubeData")
        return filter?.outputImage?.cropped(to: image.extent) ?? image
    }

    private func makeColorCube(settings: CameraBackgroundSnapshot) -> Data {
        let dimension = 32
        let key = settings.keyColor.components
        var values = [Float]()
        values.reserveCapacity(dimension * dimension * dimension * 4)
        for blueIndex in 0..<dimension {
            let blue = CGFloat(blueIndex) / CGFloat(dimension - 1)
            for greenIndex in 0..<dimension {
                let green = CGFloat(greenIndex) / CGFloat(dimension - 1)
                for redIndex in 0..<dimension {
                    let red = CGFloat(redIndex) / CGFloat(dimension - 1)
                    let distance = sqrt(
                        pow(red - key.red, 2) +
                        pow(green - key.green, 2) +
                        pow(blue - key.blue, 2)
                    ) / sqrt(3)
                    let alpha = smoothstep(
                        edge0: settings.tolerance,
                        edge1: settings.tolerance + settings.softness,
                        value: distance
                    )
                    let outputRed = red
                    var outputGreen = green
                    var outputBlue = blue
                    if settings.keyColor == .green {
                        outputGreen += (max(red, blue) - green) * settings.spillSuppression * (1 - alpha)
                    } else {
                        outputBlue += (max(red, green) - blue) * settings.spillSuppression * (1 - alpha)
                    }
                    values.append(Float(outputRed * alpha))
                    values.append(Float(outputGreen * alpha))
                    values.append(Float(outputBlue * alpha))
                    values.append(Float(alpha))
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func smoothstep(edge0: CGFloat, edge1: CGFloat, value: CGFloat) -> CGFloat {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
