import Foundation

struct FilterParameters: Codable, Equatable, Sendable {
    var redWeight: Float
    var greenWeight: Float
    var blueWeight: Float
    var contrast: Float

    // Temporary technical baseline from the original specification. The user's AA values are pending.
    static let initialAA = FilterParameters(
        redWeight: 0.2126, greenWeight: 0.7152, blueWeight: 0.0722, contrast: 0
    )

    var normalizedWeights: SIMD3<Float> {
        let values = SIMD3(
            Self.safeWeight(redWeight), Self.safeWeight(greenWeight), Self.safeWeight(blueWeight)
        )
        let sum = values.x + values.y + values.z
        guard sum > 0 else {
            return SIMD3(0.2126, 0.7152, 0.0722)
        }
        return values / sum
    }

    var safeContrast: Float {
        contrast.isFinite ? min(100, max(-100, contrast)) : 0
    }

    mutating func setWeight(_ channel: Int, to value: Float) {
        let newValue = Self.safeWeight(value)
        var values = [redWeight, greenWeight, blueWeight].map(Self.safeWeight)
        values[channel] = newValue
        // The last valid combination remains visible if the user tries to zero every channel.
        guard values.contains(where: { $0 > 0 }) else { return }
        redWeight = values[0]
        greenWeight = values[1]
        blueWeight = values[2]
    }

    private static func safeWeight(_ value: Float) -> Float {
        value.isFinite ? min(1, max(0, value)) : 0
    }
}
