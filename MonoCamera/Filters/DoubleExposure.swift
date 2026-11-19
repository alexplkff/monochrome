import CoreImage
import Foundation
import ImageIO

enum ExposureBlendMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case normal, screen, multiply
    var id: String { rawValue }
    var label: String {
        switch self {
        case .normal: "Смешивание"
        case .screen: "Screen"
        case .multiply: "Multiply"
        }
    }
}

struct DoubleExposureSettings: Codable, Equatable, Sendable {
    var mode: ExposureBlendMode = .screen
    var strength: Float = 50
    var firstBrightness: Float = 0
    var secondBrightness: Float = 0

    var safeStrength: Float { strength.isFinite ? min(100, max(0, strength)) : 50 }
    func safeBrightness(_ value: Float) -> Float { value.isFinite ? min(3, max(-3, value)) : 0 }
}

struct DoubleExposurePreview: @unchecked Sendable {
    let first: CIImage
    let settings: DoubleExposureSettings
}

enum DoubleExposureCompositor {
    // Same graph and full-frame geometry for video and photographs. The context's
    // sRGB working space is shared with the existing tone/grain pipeline.
    static func compose(first: CIImage, second: CIImage, settings: DoubleExposureSettings) -> CIImage {
        let canvas = second.extent
        let scale = min(canvas.width / first.extent.width, canvas.height / first.extent.height)
        let normalized = first.transformed(by: CGAffineTransform(translationX: -first.extent.minX,
                                                                  y: -first.extent.minY))
        let fitted = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let positioned = fitted.transformed(by: CGAffineTransform(
            translationX: canvas.midX - fitted.extent.midX, y: canvas.midY - fitted.extent.midY))
        func brighten(_ image: CIImage, _ value: Float) -> CIImage {
            image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: settings.safeBrightness(value)])
                .applyingFilter("CIColorClamp", parameters: [
                    "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
                ])
        }
        let a = brighten(positioned, settings.firstBrightness)
        let b = brighten(second, settings.secondBrightness)
        let black = CIImage(color: .black).cropped(to: canvas)
        let firstOnBlack = a.composited(over: black).cropped(to: canvas)
        let effect: CIImage
        switch settings.mode {
        case .normal: effect = b
        case .screen:
            effect = b.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: firstOnBlack])
        case .multiply:
            // Missing first-image pixels use the neutral white for Multiply, not black.
            let white = CIImage(color: .white).cropped(to: canvas)
            effect = b.applyingFilter("CIMultiplyBlendMode", parameters: [
                kCIInputBackgroundImageKey: a.composited(over: white)
            ])
        }
        let strength = settings.safeStrength / 100
        if strength == 0 { return firstOnBlack }
        if strength == 1 { return effect.cropped(to: canvas) }
        return firstOnBlack.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: effect, kCIInputTimeKey: strength
        ]).cropped(to: canvas)
    }

    static func previewImage(at url: URL, maxDimension: Int = 2048) throws -> CIImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw CameraError.invalidPhoto }
        return try decoded(source, maxDimension: maxDimension)
    }

    static func exportFirst(_ data: Data, canvas: CGRect) throws -> CIImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw CameraError.invalidPhoto }
        // No first-image detail beyond the output canvas can survive aspect-fit.
        return try decoded(source, maxDimension: Int(ceil(max(canvas.width, canvas.height))))
    }

    private static func decoded(_ source: CGImageSource, maxDimension: Int) throws -> CIImage {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw CameraError.invalidPhoto }
        return CIImage(cgImage: image)
    }
}
