// Isolated visual experiment. Not linked to MonoCamera or its photo pipeline.
// Run only after the user chooses programmatic samples.
import Foundation
import CoreGraphics
import ImageIO
import AppKit
import CoreText

struct GrayPhoto {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "GrainSamples", code: 1)
        }
        width = image.width
        height = image.height
        pixels = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
        let rendered = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        if !rendered { throw NSError(domain: "GrainSamples", code: 2) }
    }

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    var image: CGImage {
        let data = Data(pixels) as CFData
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: width, space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: CGDataProvider(data: data)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }
}

enum GrainFamily: String, CaseIterable {
    case kodak = "Kodak", ilford = "Ilford", fujifilm = "Fujifilm"
    var label: String {
        switch self {
        case .kodak: "Kodak · неоднородное"
        case .ilford: "Ilford · равномерное"
        case .fujifilm: "Fujifilm · мелкое"
        }
    }
}

func hash(_ input: UInt64) -> UInt64 {
    var value = input &+ 0x9e3779b97f4a7c15
    value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
    value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
    return value ^ (value >> 31)
}

func unit(_ input: UInt64) -> Double { Double(hash(input) >> 11) / 9_007_199_254_740_992 }

func blur(_ values: [Double], width: Int, height: Int, sigma: Double) -> [Double] {
    let radius = max(1, Int(ceil(sigma * 3)))
    var kernel = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
    let sum = kernel.reduce(0, +)
    kernel = kernel.map { $0 / sum }
    var horizontal = [Double](repeating: 0, count: values.count)
    var result = horizontal
    for y in 0..<height {
        for x in 0..<width {
            var value = 0.0
            for offset in -radius...radius {
                let xx = (x + offset + width) % width
                value += values[y * width + xx] * kernel[offset + radius]
            }
            horizontal[y * width + x] = value
        }
    }
    for y in 0..<height {
        for x in 0..<width {
            var value = 0.0
            for offset in -radius...radius {
                let yy = (y + offset + height) % height
                value += horizontal[yy * width + x] * kernel[offset + radius]
            }
            result[y * width + x] = value
        }
    }
    return result
}

func normalize(_ values: inout [Double]) {
    let mean = values.reduce(0, +) / Double(values.count)
    let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    let scale = 1 / max(0.000001, sqrt(variance))
    for index in values.indices { values[index] = (values[index] - mean) * scale }
}

// These are proposed artistic families, not measured or certified film emulations.
func texture(family: GrainFamily, iso: Int, photo: GrayPhoto, seed: UInt64 = 713_021) -> [Double] {
    let white = (0..<photo.pixels.count).map { index -> Double in
        let index = UInt64(index) &+ seed
        return unit(index) + unit(index &+ 1_000_003) + unit(index &+ 2_000_003) - 1.5
    }
    let scale = Double(min(photo.width, photo.height)) / 685 * pow(Double(iso) / 400, 0.36)
    let sigma: Double
    switch family {
    case .kodak: sigma = max(0.2, 0.72 * scale)
    case .ilford: sigma = max(0.2, 0.48 * scale)
    case .fujifilm: sigma = max(0.18, 0.32 * scale)
    }
    var field = blur(white, width: photo.width, height: photo.height, sigma: sigma)
    if family == .kodak {
        var clumps = blur(white, width: photo.width, height: photo.height, sigma: max(0.4, sigma * 2.8))
        normalize(&field)
        normalize(&clumps)
        for index in field.indices { field[index] = field[index] * 0.84 + clumps[index] * 0.32 }
    } else if family == .fujifilm {
        for index in field.indices { field[index] = tanh(field[index] * 2) }
    }
    normalize(&field)
    return field
}

func applyGrain(_ photo: GrayPhoto, field: [Double], strength: Int) -> GrayPhoto {
    if strength == 0 { return photo }
    let amplitude = 18 * Double(strength) / 100
    var delta = [Double](repeating: 0, count: photo.pixels.count)
    var sums = [Double](repeating: 0, count: 256)
    var counts = [Int](repeating: 0, count: 256)
    for index in photo.pixels.indices {
        let value = Int(photo.pixels[index])
        // Keep pure black/white unchanged and reduce amplitude near the two limits.
        let headroom = Double(min(value, 255 - value))
        let envelope = pow(max(0, sin(Double(value) / 255 * .pi)), 0.55)
        let difference = headroom > 0 ? headroom * tanh(amplitude * field[index] * envelope / headroom) : 0
        delta[index] = difference
        sums[value] += difference
        counts[value] += 1
    }
    var output = photo.pixels
    var residuals = [Int](repeating: 0, count: 256)
    for index in output.indices {
        let value = Int(photo.pixels[index])
        let mean = sums[value] / Double(max(1, counts[value]))
        output[index] = UInt8(clamping: Int((Double(value) + delta[index] - mean).rounded()))
        residuals[value] += Int(output[index]) - value
    }
    // Distribute 8-bit rounding residuals, preserving the mean of each input gray level.
    // This is a prototype neutrality rule, not a final acceptance tolerance.
    for pass in 0..<8 {
        if residuals.allSatisfy({ $0 == 0 }) { break }
        var remaining = counts
        for index in output.indices {
            let value = Int(photo.pixels[index])
            let residual = residuals[value]
            let probability = Double(abs(residual)) / Double(max(1, remaining[value]))
            remaining[value] -= 1
            guard residual != 0, unit(UInt64(index) &+ UInt64(pass) &* 11_000_027) <= probability else { continue }
            let correction = residual > 0 ? -1 : 1
            let corrected = Int(output[index]) + correction
            if (0...255).contains(corrected) {
                output[index] = UInt8(corrected)
                residuals[value] += correction
            }
        }
    }
    precondition(residuals.allSatisfy { $0 == 0 }, "Unbalanced output")
    return GrayPhoto(width: photo.width, height: photo.height, pixels: output)
}

func savePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
}

func metrics(original: GrayPhoto, result: GrayPhoto) -> [String: Any] {
    var total = 0
    var squares = 0.0
    var binSums = [Int](repeating: 0, count: 16)
    var binCounts = [Int](repeating: 0, count: 16)
    var adjacentProduct = 0.0, adjacentLeftSquares = 0.0, adjacentRightSquares = 0.0
    var linearShift = 0.0
    let linearTable = (0...255).map { pow(Double($0) / 255, 2.2) }
    for index in original.pixels.indices {
        let value = Int(original.pixels[index])
        let difference = Int(result.pixels[index]) - value
        linearShift += linearTable[Int(result.pixels[index])] - linearTable[value]
        total += difference
        squares += Double(difference * difference)
        binSums[value / 16] += difference
        binCounts[value / 16] += 1
        if index % original.width < original.width - 1 {
            let next = Int(result.pixels[index + 1]) - Int(original.pixels[index + 1])
            adjacentProduct += Double(difference * next)
            adjacentLeftSquares += Double(difference * difference)
            adjacentRightSquares += Double(next * next)
        }
    }
    let zoneMeans = zip(binSums, binCounts).map { Double($0.0) / Double(max(1, $0.1)) }
    return ["meanShift8Bit": Double(total) / Double(original.pixels.count),
            "maxTonalBinMeanShift8Bit": zoneMeans.map(abs).max() ?? 0,
            "linearLightMeanShiftNormalized": linearShift / Double(original.pixels.count),
            "adjacentPixelCorrelation": adjacentProduct / max(0.000001, sqrt(adjacentLeftSquares * adjacentRightSquares)),
            "rmsPixelChange8Bit": sqrt(squares / Double(original.pixels.count))]
}

func sheet(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 0.075, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    draw(context)
    return context.makeImage()!
}

func text(_ string: String, at x: Int, top: Int, in context: CGContext, height: Int, size: CGFloat = 18) {
    let attributed = NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor(white: 0.9, alpha: 1)
    ])
    context.textPosition = CGPoint(x: x, y: height - top - Int(size))
    CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
}

func image(_ image: CGImage, at x: Int, top: Int, width: Int, height: Int,
           in context: CGContext, sheetHeight: Int) {
    context.interpolationQuality = width == image.width && height == image.height ? .none : .high
    context.draw(image, in: CGRect(x: x, y: sheetHeight - top - height, width: width, height: height))
}

func comparison(source: GrayPhoto, variants: [GrayPhoto], crop: CGRect, title: String) -> CGImage {
    let width = 1136
    let displayedHeight = min(390, Int(256 * Double(source.height) / Double(source.width)))
    let cropTop = 120 + displayedHeight + 44
    let height = cropTop + Int(crop.height) + 30
    let labels = ["Без зерна"] + GrainFamily.allCases.map(\.label)
    return sheet(width: width, height: height) { context in
        text(title, at: 20, top: 16, in: context, height: height, size: 23)
        text("ISO зерна 400 · Сила 50% · Художественные варианты v0.1", at: 20, top: 49,
             in: context, height: height, size: 16)
        for (index, photo) in ([source] + variants).enumerated() {
            let x = 20 + index * 280
            text(labels[index], at: x, top: 88, in: context, height: height, size: 16)
            let fit = min(256 / Double(photo.width), 390 / Double(photo.height))
            let w = Int(Double(photo.width) * fit), h = Int(Double(photo.height) * fit)
            image(photo.image, at: x + (256 - w) / 2, top: 120, width: w, height: h,
                  in: context, sheetHeight: height)
            text("Фрагмент 100%", at: x, top: cropTop - 28, in: context, height: height, size: 15)
            image(photo.image.cropping(to: crop)!, at: x, top: cropTop, width: Int(crop.width), height: Int(crop.height),
                  in: context, sheetHeight: height)
        }
    }
}

func parameterGrid(family: GrainFamily, photos: [String: GrayPhoto], crop: CGRect) -> CGImage {
    let width = 836, height = 936
    return sheet(width: width, height: height) { context in
        text("\(family.rawValue) · Размер × сила", at: 20, top: 14, in: context, height: height, size: 23)
        text("Одинаковый фрагмент 100% · Сила 25% / 50% / 100% слева направо", at: 20, top: 47,
             in: context, height: height, size: 16)
        for (row, iso) in [50, 400, 3200].enumerated() {
            for (column, strength) in [25, 50, 100].enumerated() {
                let x = 20 + column * 274, top = 88 + row * 278
                let photo = photos["\(iso)-\(strength)"]!
                text("ISO \(iso) · \(strength)%", at: x, top: top, in: context, height: height, size: 16)
                image(photo.image.cropping(to: crop)!, at: x, top: top + 25,
                      width: 240, height: 240, in: context, sheetHeight: height)
            }
        }
    }
}

guard CommandLine.arguments.count == 4 else {
    fatalError("Usage: grain-samples portrait.jpg landscape.png output-directory")
}
let portrait = try GrayPhoto(url: URL(fileURLWithPath: CommandLine.arguments[1]))
let landscape = try GrayPhoto(url: URL(fileURLWithPath: CommandLine.arguments[2]))
let output = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var report: [[String: Any]] = []
let portraitCrop = CGRect(x: 165, y: 388, width: 240, height: 240)
var portraitVariants: [GrayPhoto] = []
var landscapeVariants: [GrayPhoto] = []

for (name, source, crop) in [("portrait", portrait, portraitCrop),
                              ("landscape", landscape, CGRect(x: 390, y: 325, width: 240, height: 240))] {
    savePNG(source.image, to: output.appendingPathComponent("\(name)-original.png"))
    let isos = name == "portrait" ? [50, 400, 3200] : [400]
    let strengths = name == "portrait" ? [25, 50, 100] : [50]
    for family in GrainFamily.allCases {
        var photos: [String: GrayPhoto] = [:]
        for iso in isos {
            let field = texture(family: family, iso: iso, photo: source)
            precondition(applyGrain(source, field: field, strength: 0).pixels == source.pixels)
            for strength in strengths {
                let result = applyGrain(source, field: field, strength: strength)
                precondition(zip(source.pixels, result.pixels).allSatisfy {
                    ($0.0 != 0 && $0.0 != 255) || $0.0 == $0.1
                }, "Pure black and white must stay unchanged")
                let filename = "\(name)-\(family.rawValue.lowercased())-iso\(iso)-strength\(strength).png"
                savePNG(result.image, to: output.appendingPathComponent(filename))
                photos["\(iso)-\(strength)"] = result
                var row = metrics(original: source, result: result)
                row["file"] = filename
                row["family"] = family.rawValue
                row["iso"] = iso
                row["strength"] = strength
                report.append(row)
                if iso == 400 && strength == 50 {
                    if name == "portrait" { portraitVariants.append(result) }
                    else { landscapeVariants.append(result) }
                }
            }
        }
        if name == "portrait" {
            let grid = parameterGrid(family: family, photos: photos, crop: crop)
            savePNG(grid, to: output.appendingPathComponent("grid-\(family.rawValue.lowercased()).png"))
        }
    }
}
savePNG(comparison(source: portrait, variants: portraitVariants, crop: portraitCrop,
                   title: "Зерно · сравнение на портрете"), to: output.appendingPathComponent("compare-portrait.png"))
savePNG(comparison(source: landscape, variants: landscapeVariants,
                   crop: CGRect(x: 390, y: 325, width: 240, height: 240),
                   title: "Зерно · сравнение на пейзаже"), to: output.appendingPathComponent("compare-landscape.png"))
let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
try json.write(to: output.appendingPathComponent("metrics.json"))
print("Generated \(report.count) variants and five comparison sheets. Neutrality and zero-strength checks passed.")
