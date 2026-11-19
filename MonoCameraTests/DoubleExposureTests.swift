import XCTest
import CoreImage
import ImageIO
import Metal
import UniformTypeIdentifiers
#if canImport(MonoCamera)
@testable import MonoCamera
#else
@testable import MonoCameraCore
#endif

final class DoubleExposureTests: XCTestCase, @unchecked Sendable {
    func testBlendEndpointsAndNeutralColors() throws {
        let engine = try engine()
        let a = image(0.2), b = image(0.8)
        let aPixels = pixels(a, engine), bPixels = pixels(b, engine)
        for mode in ExposureBlendMode.allCases {
            var settings = DoubleExposureSettings(mode: mode, strength: 0)
            XCTAssertEqual(pixels(DoubleExposureCompositor.compose(first: a, second: b, settings: settings), engine), aPixels)
            settings.strength = 100
            let result = DoubleExposureCompositor.compose(first: a, second: b, settings: settings)
            if mode == .normal { XCTAssertEqual(pixels(result, engine), bPixels) }
            if mode == .screen {
                XCTAssertEqual(pixels(DoubleExposureCompositor.compose(first: image(0), second: b, settings: settings), engine), bPixels)
                XCTAssertEqual(pixels(DoubleExposureCompositor.compose(first: image(1), second: b, settings: settings), engine), pixels(image(1), engine))
            }
            if mode == .multiply {
                XCTAssertEqual(pixels(DoubleExposureCompositor.compose(first: image(1), second: b, settings: settings), engine), bPixels)
                XCTAssertEqual(pixels(DoubleExposureCompositor.compose(first: image(0), second: b, settings: settings), engine), pixels(image(0), engine))
            }
        }
        let equal = DoubleExposureCompositor.compose(first: a, second: b,
                                                     settings: DoubleExposureSettings(mode: .normal, strength: 50))
        let expected = (Double(aPixels[0]) + Double(bPixels[0])) / 2
        XCTAssertEqual(Double(pixels(equal, engine)[0]), expected, accuracy: 1)
    }

    func testWholeFrameFitAndOutsidePixelsAcrossAllModes() throws {
        let engine = try engine()
        let first = image(0.4, rect: CGRect(x: 17, y: 21, width: 40, height: 20))
        let second = image(0.8, rect: CGRect(x: 5, y: 7, width: 40, height: 80))
        for mode in ExposureBlendMode.allCases {
            var settings = DoubleExposureSettings(mode: mode, strength: 0)
            let zero = DoubleExposureCompositor.compose(first: first, second: second, settings: settings)
            XCTAssertEqual(zero.extent, second.extent)
            let bytes = pixels(zero, engine)
            XCTAssertEqual(bytes[0], 0)
            XCTAssertGreaterThan(bytes[(40 * 40 + 20) * 4], 0)
            settings.strength = 100
            let full = pixels(DoubleExposureCompositor.compose(first: first, second: second, settings: settings), engine)
            XCTAssertEqual(full[0], pixels(second, engine)[0], "Outside first must show second even in Multiply")
            settings.strength = 50
            let half = pixels(DoubleExposureCompositor.compose(first: first, second: second, settings: settings), engine)
            XCTAssertEqual(Double(half[0]), Double(full[0]) / 2, accuracy: 1)
        }
    }

    func testSettingsAndWaitingFirstRestoreAndCancelWithoutChangingPreferences() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DoubleExposureStore(directory: directory)
        try await store.setEnabled(true)
        let settings = DoubleExposureSettings(mode: .multiply, strength: 72, firstBrightness: -1.3, secondBrightness: 0.7)
        try await store.setSettings(settings)
        let first = try photo(0.3)
        let record = try await store.begin(first: first, imported: false)
        try await store.markSaved(record.id, component: 0)
        let restored = DoubleExposureStore(directory: directory)
        let state = await restored.snapshot()
        XCTAssertTrue(state.enabled)
        XCTAssertEqual(state.settings, settings)
        XCTAssertEqual(state.activeID, record.id)
        let source = try await restored.source(record.id)
        XCTAssertEqual(source, first)
        try await restored.cancelActive()
        let cancelled = await restored.snapshot()
        XCTAssertNil(cancelled.activeID)
        XCTAssertTrue(cancelled.records.isEmpty)
        XCTAssertEqual(cancelled.settings, settings)
    }

    func testFailedCompositionRetainsSourcesAndRetryDoesNotDuplicateOriginals() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DoubleExposureStore(directory: directory)
        let first = try photo(0.2), second = try photo(0.8)
        let result = Data([91, 92, 93])
        let saver = ExposureSaveProbe(result: result)
        let record = try await store.begin(first: first, imported: false)
        let originalJob = ExposureJob(id: record.id, originalOnly: true, bufferedBytes: first.count)
        _ = await ExposureProcessor.process(originalJob, store: store,
                                            render: { _, _, _, _, _ in result }, save: { await saver.save($0) })
        var params = FilterParameters.initialAA
        params.grain = GrainSettings(brand: .ilford, iso: 800, strength: 30)
        let capturedParameters = params
        let settings = DoubleExposureSettings(mode: .screen, strength: 66)
        let job = try await store.finish(second: second, parameters: params, settings: settings)
        let outcome = await ExposureProcessor.process(job, store: store,
                                                       render: { _, _, _, _, _ in result }, save: { await saver.save($0) })
        guard case .failed = outcome else { return XCTFail("Composition failure must be reported") }
        let failed = try await store.record(record.id)
        XCTAssertEqual(failed.stage, .failed)
        XCTAssertTrue(failed.firstSaved)
        XCTAssertTrue(failed.secondSaved)
        XCTAssertFalse(failed.resultSaved)
        XCTAssertEqual(failed.parameters, params)
        let restored = DoubleExposureStore(directory: directory)
        let retry = try await restored.retry(record.id)
        let outcome2 = await ExposureProcessor.process(retry, store: restored, render: { a, b, parameters, blend, seed in
            XCTAssertEqual(a, first); XCTAssertEqual(b, second)
            XCTAssertEqual(parameters, capturedParameters); XCTAssertEqual(blend, settings)
            XCTAssertEqual(seed, failed.grainSeed)
            return result
        }, save: { await saver.save($0) })
        guard case .saved = outcome2 else { return XCTFail("Retry must complete") }
        let calls = await saver.calls
        XCTAssertEqual(calls.filter { $0 == first }.count, 1)
        XCTAssertEqual(calls.filter { $0 == second }.count, 1)
        XCTAssertEqual(calls.filter { $0 == result }.count, 2)
        let final = await restored.snapshot()
        XCTAssertTrue(final.records.isEmpty)
        XCTAssertNil(final.activeID)
    }

    func testImportedFirstIsNotSavedAndPendingCompositionRecoversAsFailed() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DoubleExposureStore(directory: directory)
        let first = try photo(0.3), second = try photo(0.6)
        let record = try await store.begin(first: first, imported: true)
        _ = try await store.finish(second: second, parameters: .initialAA, settings: DoubleExposureSettings())
        let restored = DoubleExposureStore(directory: directory)
        let loaded = try await restored.record(record.id)
        XCTAssertTrue(loaded.firstSaved)
        XCTAssertEqual(loaded.stage, .failed)
        let saver = ExposureSaveProbe(result: Data([99]), failResult: false)
        let retry = try await restored.retry(record.id)
        _ = await ExposureProcessor.process(retry, store: restored, render: { _, _, _, _, _ in Data([99]) },
                                            save: { await saver.save($0) })
        let calls = await saver.calls
        XCTAssertFalse(calls.contains(first))
        XCTAssertEqual(calls.count, 2)
    }

    func testCancelBeforeOriginalWriteStillPreservesThatWrite() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DoubleExposureStore(directory: directory)
        let first = try photo(0.3)
        let record = try await store.begin(first: first, imported: false)
        try await store.cancelActive()
        let abandoned = try await store.record(record.id)
        XCTAssertEqual(abandoned.stage, .abandoned)
        let saver = ExposureSaveProbe(result: Data(), failResult: false)
        _ = await ExposureProcessor.process(ExposureJob(id: record.id, originalOnly: true, bufferedBytes: first.count),
                                            store: store, render: { _, _, _, _, _ in Data() },
                                            save: { await saver.save($0) })
        let calls = await saver.calls
        XCTAssertEqual(calls, [first])
        let state = await store.snapshot()
        XCTAssertTrue(state.records.isEmpty)
    }

    func testCompletedReceiptsRecoverWithoutWritingAnyAssetsAgain() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DoubleExposureStore(directory: directory)
        let record = try await store.begin(first: photo(0.2), imported: false)
        _ = try await store.finish(second: photo(0.8), parameters: .initialAA, settings: DoubleExposureSettings())
        // Simulate termination after all write receipts, before local cleanup.
        for component in 0...2 { try await store.markSaved(record.id, component: component) }
        let restored = DoubleExposureStore(directory: directory)
        let saver = ExposureSaveProbe(result: Data(), failResult: false)
        let retry = try await restored.retry(record.id)
        let result = await ExposureProcessor.process(retry, store: restored,
                                                     render: { _, _, _, _, _ in XCTFail("Already rendered"); return Data() },
                                                     save: { await saver.save($0) })
        guard case .saved = result else { return XCTFail("Cleanup retry must succeed") }
        let calls = await saver.calls
        XCTAssertTrue(calls.isEmpty)
        let state = await restored.snapshot()
        XCTAssertTrue(state.records.isEmpty)
    }

    func testRetainedFailedRecordsAreBoundedAndParametersAreSnapshots() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DoubleExposureStore(directory: directory)
        let first = try photo(0.2), second = try photo(0.7)
        var settings = DoubleExposureSettings(mode: .multiply, strength: 77)
        let initialSettings = settings
        for _ in 0..<3 {
            let record = try await store.begin(first: first, imported: true)
            _ = try await store.finish(second: second, parameters: .initialAA, settings: settings)
            try await store.markFailed(record.id, originalOnly: false, message: "Test failure")
        }
        settings.strength = 2
        try await store.setSettings(settings)
        let state = await store.snapshot()
        XCTAssertEqual(state.records.count, 3)
        XCTAssertTrue(state.records.allSatisfy { $0.settings == initialSettings })
        do { _ = try await store.begin(first: first, imported: true); XCTFail("Unbounded failed drafts") }
        catch { }
        try await store.discardFailed(state.records[0].id)
        let next = try await store.begin(first: first, imported: true)
        XCTAssertEqual(next.settings.strength, 2)
    }

    func testInvalidImportDoesNotCreateDraftAndSettingsClamp() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DoubleExposureStore(directory: directory)
        do { _ = try await store.begin(first: Data([1, 2, 3]), imported: true); XCTFail("Invalid photo accepted") }
        catch { }
        let state = await store.snapshot()
        XCTAssertNil(state.activeID)
        XCTAssertTrue(state.records.isEmpty)
        var settings = DoubleExposureSettings(strength: .nan, firstBrightness: .infinity, secondBrightness: -10)
        XCTAssertEqual(settings.safeStrength, 50)
        XCTAssertEqual(settings.safeBrightness(settings.firstBrightness), 0)
        XCTAssertEqual(settings.safeBrightness(settings.secondBrightness), -3)
        settings.strength = 999
        XCTAssertEqual(settings.safeStrength, 100)
    }

    func testJPEGExportUsesSecondDimensionsAndWholeCompositeThenGrain() throws {
        let engine = try engine()
        let first = try photo(0.2, width: 120, height: 60)
        let second = try photo(0.8, width: 96, height: 128)
        var params = FilterParameters.initialAA
        params.grain.strength = 40
        let jpeg = try engine.jpeg(from: second, parameters: params, grainSeed: 17, firstExposure: first,
                                   exposureSettings: DoubleExposureSettings(mode: .multiply, strength: 100))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 96)
        XCTAssertEqual(image.height, 128)
    }

    private func image(_ value: CGFloat, rect: CGRect = CGRect(x: 0, y: 0, width: 32, height: 32)) -> CIImage {
        CIImage(color: CIColor(red: value, green: value, blue: value)).cropped(to: rect)
    }
    private func engine() throws -> FilterEngine {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        return FilterEngine(metalDevice: device)
    }
    private func pixels(_ image: CIImage, _ engine: FilterEngine) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: Int(image.extent.width * image.extent.height) * 4)
        result.withUnsafeMutableBytes {
            engine.context.render(image, toBitmap: $0.baseAddress!, rowBytes: Int(image.extent.width) * 4,
                                  bounds: image.extent, format: .RGBA8, colorSpace: engine.colorSpace)
        }
        return result
    }
    private func photo(_ value: CGFloat, width: Int = 32, height: Int = 32) throws -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: colorSpace,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: value, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let output = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(output))
        return data as Data
    }
    private func tempDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
}

private actor ExposureSaveProbe {
    let result: Data
    var failResult: Bool
    var calls: [Data] = []
    init(result: Data, failResult: Bool = true) { self.result = result; self.failResult = failResult }
    func save(_ data: Data) -> Bool {
        calls.append(data)
        if data == result && failResult { failResult = false; return false }
        return true
    }
}
