import XCTest
import CoreImage
import Metal
#if canImport(MonoCamera)
@testable import MonoCamera
#else
@testable import MonoCameraCore
#endif

final class MonoCameraTests: XCTestCase {
    func testWeightsNormalizeAndPreserveLastValidCombination() {
        var parameters = FilterParameters(redWeight: 1, greenWeight: 0, blueWeight: 0, contrast: 0)
        parameters.setWeight(0, to: 0)
        XCTAssertEqual(parameters.redWeight, 1)
        parameters.setWeight(1, to: 1)
        parameters.setWeight(0, to: 0)
        XCTAssertEqual(parameters.normalizedWeights.y, 1, accuracy: 0.0001)
        XCTAssertEqual(parameters.normalizedWeights.x, 0, accuracy: 0.0001)
    }

    func testNonFiniteInputsCannotReachFilter() {
        let parameters = FilterParameters(redWeight: .nan, greenWeight: .infinity,
                                          blueWeight: -1, contrast: .infinity)
        XCTAssertEqual(parameters.normalizedWeights.x, 0.2126, accuracy: 0.0001)
        XCTAssertEqual(parameters.safeContrast, 0)
    }

    func testRepositoryPersistsIdentityAndDiscardRules() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = PresetRepository(url: url)
        XCTAssertEqual(repository.selected.label, "AA")
        let created = try XCTUnwrap(repository.create())
        XCTAssertEqual(created.number, 1)
        XCTAssertEqual(created.parameters, .initialAA)
        XCTAssertTrue(repository.rename(1, to: 5))
        var changed = FilterParameters.initialAA
        changed.contrast = 40
        repository.save(changed, for: 5)
        let reopened = PresetRepository(url: url)
        XCTAssertEqual(reopened.selected.number, 5)
        XCTAssertEqual(reopened.selected.parameters.contrast, 40)
        XCTAssertTrue(reopened.delete(5))
        XCTAssertEqual(reopened.selected.number, 0)
        XCTAssertEqual(reopened.create()?.number, 1)
    }

    func testMixerChangesRedSubjectBrightness() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let engine = FilterEngine(metalDevice: device)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))

        func brightness(_ parameters: FilterParameters) -> UInt8 {
            var pixel = [UInt8](repeating: 0, count: 4)
            let result = engine.apply(red, parameters: parameters)
            engine.context.render(result, toBitmap: &pixel, rowBytes: 4,
                                  bounds: red.extent, format: .RGBA8, colorSpace: engine.colorSpace)
            XCTAssertEqual(pixel[0], pixel[1])
            XCTAssertEqual(pixel[1], pixel[2])
            return pixel[0]
        }

        let onlyRed = FilterParameters(redWeight: 1, greenWeight: 0, blueWeight: 0, contrast: 0)
        let onlyBlue = FilterParameters(redWeight: 0, greenWeight: 0, blueWeight: 1, contrast: 0)
        XCTAssertGreaterThan(brightness(onlyRed), 245)
        XCTAssertLessThan(brightness(onlyBlue), 10)
    }
}
