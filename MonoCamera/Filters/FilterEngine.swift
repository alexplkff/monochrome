import CoreImage
import CoreGraphics
import Foundation
import Metal
import ImageIO
import UniformTypeIdentifiers

final class FilterEngine: @unchecked Sendable {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context: CIContext

    init(metalDevice: MTLDevice) {
        context = CIContext(mtlDevice: metalDevice, options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
            .cacheIntermediates: false
        ])
    }

    func apply(_ image: CIImage, parameters: FilterParameters, compare: Bool = false) -> CIImage {
        if compare { return image }
        let weights = parameters.normalizedWeights
        let monochrome = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(weights.x), y: CGFloat(weights.y), z: CGFloat(weights.z), w: 0),
            "inputGVector": CIVector(x: CGFloat(weights.x), y: CGFloat(weights.y), z: CGFloat(weights.z), w: 0),
            "inputBVector": CIVector(x: CGFloat(weights.x), y: CGFloat(weights.y), z: CGFloat(weights.z), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
        // UI contrast -100...100 maps linearly to Core Image contrast 0...2.
        return monochrome.applyingFilter("CIColorControls", parameters: [
            kCIInputContrastKey: 1 + parameters.safeContrast / 100
        ])
    }

    func jpeg(from data: Data, parameters: FilterParameters) throws -> Data {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw CameraError.invalidPhoto
        }
        let result = apply(image, parameters: parameters)
        var properties = image.properties
        // Pixel orientation has already been applied, so the output metadata must say upright.
        properties[kCGImagePropertyOrientation as String] = 1
        guard let cgImage = context.createCGImage(result, from: result.extent,
                                                  format: .RGBA8, colorSpace: colorSpace) else {
            throw CameraError.photoProcessingFailed
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData,
                                                                 UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CameraError.photoProcessingFailed
        }
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.94
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CameraError.photoProcessingFailed }
        return output as Data
    }
}
