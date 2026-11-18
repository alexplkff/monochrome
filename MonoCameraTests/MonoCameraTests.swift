import XCTest
import CoreImage
import CoreGraphics
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

    func testLevelsPreserveOldProfilesAndMoveMiddleGray() throws {
        let oldJSON = #"{"redWeight":0.2126,"greenWeight":0.7152,"blueWeight":0.0722,"contrast":0}"#
        var parameters = try JSONDecoder().decode(FilterParameters.self, from: Data(oldJSON.utf8))
        XCTAssertFalse(parameters.hasLevels)
        var levels = parameters.masterLevels
        levels.set(1, to: 0.25)
        parameters.masterLevels = levels
        XCTAssertEqual(levels.map(0.25), 0.5, accuracy: 0.001)
        XCTAssertGreaterThan(levels.map(0.5), 0.5)
        let reopened = try JSONDecoder().decode(FilterParameters.self, from: JSONEncoder().encode(parameters))
        XCTAssertEqual(reopened, parameters)
    }

    func testLevelsAffectPreviewPixels() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let engine = FilterEngine(metalDevice: device)
        let gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        func value(_ parameters: FilterParameters) -> UInt8 {
            var pixel = [UInt8](repeating: 0, count: 4)
            engine.context.render(engine.apply(gray, parameters: parameters), toBitmap: &pixel,
                                  rowBytes: 4, bounds: gray.extent, format: .RGBA8,
                                  colorSpace: engine.colorSpace)
            return pixel[0]
        }
        var changed = FilterParameters.initialAA
        changed.masterLevels.set(1, to: 0.25)
        XCTAssertGreaterThan(value(changed), value(.initialAA))
    }

    func testTapFocusMapsPortraitImageAndIgnoresBlackBars() throws {
        let preview = CGSize(width: 300, height: 500)
        let frame = CGSize(width: 300, height: 400)
        XCTAssertNil(FocusPointMapper.devicePoint(for: CGPoint(x: 150, y: 20),
                                                   previewSize: preview, frameSize: frame))
        let center = try XCTUnwrap(FocusPointMapper.devicePoint(for: CGPoint(x: 150, y: 250),
                                                                 previewSize: preview, frameSize: frame))
        XCTAssertEqual(center.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(center.y, 0.5, accuracy: 0.001)
        let upperLeft = try XCTUnwrap(FocusPointMapper.devicePoint(for: CGPoint(x: 0, y: 50),
                                                                    previewSize: preview, frameSize: frame))
        XCTAssertEqual(upperLeft.x, 0, accuracy: 0.001)
        XCTAssertEqual(upperLeft.y, 1, accuracy: 0.001)
    }
}
