import CoreImage
import CoreGraphics
import Foundation
import Metal
import ImageIO
import UniformTypeIdentifiers

final class FilterEngine: @unchecked Sendable {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context: CIContext
    let supportsGrain: Bool
    private let cubeLock = NSLock()
    private var cachedParameters: FilterParameters?
    private var cachedCube: Data?

    init(metalDevice: MTLDevice) {
        context = CIContext(mtlDevice: metalDevice, options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
            .cacheIntermediates: false
        ])
        do {
            try FilmGrainFilter.prepare(device: metalDevice)
            supportsGrain = true
        } catch {
            supportsGrain = false
            NSLog("Film grain pipeline failed: %@", String(describing: error))
        }
    }

    func apply(_ image: CIImage, parameters: FilterParameters, compare: Bool = false,
               includesGrain: Bool = true, grainSeed: UInt32 = 713_021) -> CIImage {
        if compare { return image }
        let monochrome: CIImage
        if parameters.hasLevels {
            monochrome = image.applyingFilter("CIColorCube", parameters: [
                "inputCubeDimension": 32,
                "inputCubeData": cubeData(for: parameters)
            ])
        } else {
            let weights = parameters.normalizedWeights
            monochrome = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(weights.x), y: CGFloat(weights.y), z: CGFloat(weights.z), w: 0),
                "inputGVector": CIVector(x: CGFloat(weights.x), y: CGFloat(weights.y), z: CGFloat(weights.z), w: 0),
                "inputBVector": CIVector(x: CGFloat(weights.x), y: CGFloat(weights.y), z: CGFloat(weights.z), w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
        }
        // UI contrast -100...100 maps linearly to Core Image contrast 0...2.
        let toned = monochrome.applyingFilter("CIColorControls", parameters: [
            kCIInputContrastKey: 1 + parameters.safeContrast / 100
        ])
        guard includesGrain, parameters.grain.safeStrength > 0, supportsGrain else { return toned }
        return (try? FilmGrainFilter.apply(to: toned, settings: parameters.grain, seed: grainSeed)) ?? toned
    }

    private func cubeData(for parameters: FilterParameters) -> Data {
        var parameters = parameters
        parameters.grain = .initial // Grain edits must not rebuild the tone lookup table.
        cubeLock.lock()
        defer { cubeLock.unlock() }
        if cachedParameters == parameters, let cachedCube { return cachedCube }
        let dimension = 32
        let weights = parameters.normalizedWeights
        let redCurve = parameters.redLevels.transfer
        let greenCurve = parameters.greenLevels.transfer
        let blueCurve = parameters.blueLevels.transfer
        let masterCurve = parameters.masterLevels.transfer
        let denominator = Float(dimension - 1)
        let reds = (0..<dimension).map { redCurve.map(Float($0) / denominator) }
        let greens = (0..<dimension).map { greenCurve.map(Float($0) / denominator) }
        let blues = (0..<dimension).map { blueCurve.map(Float($0) / denominator) }
        var values = [Float]()
        values.reserveCapacity(dimension * dimension * dimension * 4)
        for blue in 0..<dimension {
            for green in 0..<dimension {
                for red in 0..<dimension {
                    let r = reds[red]
                    let g = greens[green]
                    let b = blues[blue]
                    let luminance = r * weights.x + g * weights.y + b * weights.z
                    let output = masterCurve.map(luminance)
                    values.append(contentsOf: [output, output, output, 1])
                }
            }
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        cachedParameters = parameters
        cachedCube = data
        return data
    }

    func jpeg(from data: Data, parameters: FilterParameters, grainSeed: UInt32 = 713_021) throws -> Data {
        if parameters.grain.safeStrength > 0 && !supportsGrain {
            throw CameraError.photoProcessingFailed
        }
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw CameraError.invalidPhoto
        }
        // An enabled effect must never silently disappear from a saved photograph.
        let toned = apply(image, parameters: parameters, includesGrain: false)
        let result = try FilmGrainFilter.apply(to: toned, settings: parameters.grain, seed: grainSeed)
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
