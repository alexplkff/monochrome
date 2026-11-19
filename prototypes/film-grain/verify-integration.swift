// Exercises the actual application filter; the v0.1 sample generator remains independent.
import Foundation
import CoreImage
import Metal
import ImageIO

@main struct VerifyIntegration {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4, let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Usage: verify-integration portrait landscape output-directory")
        }
        let engine = FilterEngine(metalDevice: device)
        guard engine.supportsGrain else { fatalError("Grain shader compilation failed") }
        let directory = URL(fileURLWithPath: args[3], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var records = [[String: Any]]()
        for (name, path) in [("portrait", args[1]), ("landscape", args[2])] {
            try autoreleasepool {
                guard let input = CIImage(contentsOf: URL(fileURLWithPath: path), options: [.applyOrientationProperty: true]) else {
                    fatalError("Cannot decode input")
                }
                let baseline = engine.apply(input, parameters: .initialAA)
                let original = bytes(baseline, engine: engine)
                try write(baseline, name: "\(name)-baseline", directory: directory, engine: engine)
                for brand in GrainBrand.allCases {
                    for iso: Float in [50, 400, 3200] {
                        var parameters = FilterParameters.initialAA
                        parameters.grain = GrainSettings(brand: brand, iso: iso, strength: 100)
                        let start = Date()
                        let result = engine.apply(input, parameters: parameters)
                        let rendered = bytes(result, engine: engine)
                        let elapsed = Date().timeIntervalSince(start)
                        let filename = "\(name)-\(brand.rawValue)-\(Int(iso))-100"
                        try write(result, name: filename, directory: directory, engine: engine)
                        var sums = [Double](repeating: 0, count: 16)
                        var counts = [Int](repeating: 0, count: 16)
                        var total = 0.0, linear = 0.0, squared = 0.0
                        for i in stride(from: 0, to: original.count, by: 4) {
                            let delta = Double(rendered[i]) - Double(original[i])
                            let bin = min(15, Int(original[i]) * 16 / 256)
                            sums[bin] += delta; counts[bin] += 1
                            total += delta; squared += delta * delta
                            linear += decode(Double(rendered[i]) / 255) - decode(Double(original[i]) / 255)
                        }
                        let pixels = Double(original.count / 4)
                        let maximum = zip(sums, counts).map { abs($0.0) / Double(max(1, $0.1)) }.max()!
                        records.append(["image": filename, "meanShift8Bit": total / pixels,
                                        "maxTonalBinMeanShift8Bit": maximum,
                                        "linearSRGBMeanShift": linear / pixels,
                                        "rms8Bit": sqrt(squared / pixels), "renderSecondsMac": elapsed])
                    }
                }
            }
        }
        // A portrait-sized 24 MP export through the same JPEG API used by the saving queue.
        let inputData = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        let source = CIImage(data: inputData)!
        let large = source.transformed(by: CGAffineTransform(scaleX: 4284 / source.extent.width,
                                                             y: 5712 / source.extent.height))
        let largeURL = directory.appendingPathComponent("24mp-input.jpg")
        try engine.context.writeJPEGRepresentation(of: large, to: largeURL, colorSpace: engine.colorSpace,
                                                   options: [:])
        var parameters = FilterParameters.initialAA
        parameters.grain = GrainSettings(brand: .kodak, iso: 3200, strength: 100)
        let start = Date()
        let jpeg = try engine.jpeg(from: Data(contentsOf: largeURL), parameters: parameters, grainSeed: 12345)
        let elapsed = Date().timeIntervalSince(start)
        try jpeg.write(to: directory.appendingPathComponent("24mp-grain.jpg"))
        let decoded = CGImageSourceCreateWithData(jpeg as CFData, nil)!
        let photo = CGImageSourceCreateImageAtIndex(decoded, 0, nil)!
        precondition(photo.width == 4284 && photo.height == 5712)
        let report: [String: Any] = ["device": device.name, "records": records,
                                   "export24MPSecondsMac": elapsed, "export24MPBytes": jpeg.count,
                                   "exportWidth": photo.width, "exportHeight": photo.height]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("integration-metrics.json"))
        print("Verified \(records.count) variants; 24 MP JPEG \(photo.width)×\(photo.height), \(elapsed)s on \(device.name)")
    }

    static func decode(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }

    static func bytes(_ image: CIImage, engine: FilterEngine) -> [UInt8] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var values = [UInt8](repeating: 0, count: width * height * 4)
        values.withUnsafeMutableBytes {
            engine.context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 4,
                                  bounds: image.extent, format: .RGBA8, colorSpace: engine.colorSpace)
        }
        return values
    }

    static func write(_ image: CIImage, name: String, directory: URL, engine: FilterEngine) throws {
        try engine.context.writePNGRepresentation(of: image, to: directory.appendingPathComponent(name + ".png"),
                                                   format: .RGBA8, colorSpace: engine.colorSpace)
    }
}
