import Foundation

enum GrainBrand: String, Codable, CaseIterable, Identifiable, Sendable {
    case kodak, ilford, fujifilm
    var id: String { rawValue }
    var label: String {
        switch self {
        case .kodak: "Kodak"
        case .ilford: "Ilford"
        case .fujifilm: "Fujifilm"
        }
    }
    var index: Float { Float(Self.allCases.firstIndex(of: self)!) }
}

struct GrainSettings: Codable, Equatable, Sendable {
    var brand: GrainBrand = .kodak
    var iso: Float = 400
    var strength: Float = 0
    static let initial = GrainSettings()
    var safeISO: Float { iso.isFinite ? min(3200, max(50, iso)) : 400 }
    var safeStrength: Float { strength.isFinite ? min(100, max(0, strength)) : 0 }
}

enum LevelChannel: Int, CaseIterable, Identifiable {
    case master, red, green, blue
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .master: "Все"
        case .red: "Красный"
        case .green: "Зелёный"
        case .blue: "Синий"
        }
    }
}

struct LevelAdjustment: Codable, Equatable, Sendable {
    var black: Float = 0
    var middle: Float = 0.5
    var white: Float = 1

    static let identity = LevelAdjustment()
    var isIdentity: Bool { self == .identity }

    mutating func set(_ handle: Int, to value: Float) {
        guard value.isFinite else { return }
        let value = min(1, max(0, value))
        switch handle {
        case 0: black = min(value, middle - 0.02)
        case 1: middle = min(white - 0.02, max(black + 0.02, value))
        case 2: white = max(value, middle + 0.02)
        default: break
        }
    }

    func map(_ input: Float) -> Float {
        transfer.map(input)
    }

    var transfer: LevelTransfer {
        let black = min(0.96, max(0, self.black))
        let white = max(black + 0.02, min(1, self.white))
        let middle = max(black + 0.01, min(white - 0.01, self.middle))
        let position = (middle - black) / (white - black)
        let exponent = logf(0.5) / logf(position)
        return LevelTransfer(black: black, white: white, exponent: exponent)
    }
}

struct LevelTransfer {
    let black: Float
    let white: Float
    let exponent: Float

    func map(_ input: Float) -> Float {
        let normalized = min(1, max(0, (input - black) / (white - black)))
        return powf(normalized, exponent)
    }
}

struct FilterParameters: Codable, Equatable, Sendable {
    var redWeight: Float
    var greenWeight: Float
    var blueWeight: Float
    var contrast: Float
    var masterLevels: LevelAdjustment = .identity
    var redLevels: LevelAdjustment = .identity
    var greenLevels: LevelAdjustment = .identity
    var blueLevels: LevelAdjustment = .identity
    var grain: GrainSettings = .initial

    private enum CodingKeys: String, CodingKey {
        case redWeight, greenWeight, blueWeight, contrast
        case masterLevels, redLevels, greenLevels, blueLevels
        case grain
    }

    init(redWeight: Float, greenWeight: Float, blueWeight: Float, contrast: Float,
         masterLevels: LevelAdjustment = .identity, redLevels: LevelAdjustment = .identity,
         greenLevels: LevelAdjustment = .identity, blueLevels: LevelAdjustment = .identity,
         grain: GrainSettings = .initial) {
        self.redWeight = redWeight
        self.greenWeight = greenWeight
        self.blueWeight = blueWeight
        self.contrast = contrast
        self.masterLevels = masterLevels
        self.redLevels = redLevels
        self.greenLevels = greenLevels
        self.blueLevels = blueLevels
        self.grain = grain
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        redWeight = try container.decode(Float.self, forKey: .redWeight)
        greenWeight = try container.decode(Float.self, forKey: .greenWeight)
        blueWeight = try container.decode(Float.self, forKey: .blueWeight)
        contrast = try container.decode(Float.self, forKey: .contrast)
        masterLevels = try container.decodeIfPresent(LevelAdjustment.self, forKey: .masterLevels) ?? .identity
        redLevels = try container.decodeIfPresent(LevelAdjustment.self, forKey: .redLevels) ?? .identity
        greenLevels = try container.decodeIfPresent(LevelAdjustment.self, forKey: .greenLevels) ?? .identity
        blueLevels = try container.decodeIfPresent(LevelAdjustment.self, forKey: .blueLevels) ?? .identity
        grain = try container.decodeIfPresent(GrainSettings.self, forKey: .grain) ?? .initial
    }

    func levels(for channel: LevelChannel) -> LevelAdjustment {
        switch channel {
        case .master: masterLevels
        case .red: redLevels
        case .green: greenLevels
        case .blue: blueLevels
        }
    }

    mutating func setLevels(_ levels: LevelAdjustment, for channel: LevelChannel) {
        switch channel {
        case .master: masterLevels = levels
        case .red: redLevels = levels
        case .green: greenLevels = levels
        case .blue: blueLevels = levels
        }
    }

    var hasLevels: Bool {
        !masterLevels.isIdentity || !redLevels.isIdentity ||
        !greenLevels.isIdentity || !blueLevels.isIdentity
    }

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
