import XCTest
import CoreImage
import CoreGraphics
import Metal
#if canImport(MonoCamera)
@testable import MonoCamera
#else
@testable import MonoCameraCore
#endif

final class MonoCameraTests: XCTestCase, @unchecked Sendable {
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

    @MainActor
    func testSlowSaveAllowsNextCaptureAndProcessesBurstInOrder() async throws {
        let processor = ControlledPhotoProcessor()
        let queue = PhotoProcessingQueue { job in await processor.process(job) }
        let drained = expectation(description: "All three photos saved")
        queue.onStateChange = { state in
            if state.pendingCount == 0 { drained.fulfill() }
        }
        var parameters = FilterParameters.initialAA
        for index in 1...3 {
            let reservation = try XCTUnwrap(queue.beginCapture())
            XCTAssertTrue(queue.state.isCapturing)
            XCTAssertNil(queue.beginCapture(), "Only one AVFoundation capture may be in flight")
            parameters.contrast = Float(index * 10)
            queue.finishCapture(reservation, original: Data([UInt8(index)]), parameters: parameters)
            XCTAssertFalse(queue.state.isCapturing, "PhotoKit must not keep the camera busy")
            if index < 3 { XCTAssertTrue(queue.state.canCapture, "Save is still suspended") }
        }
        XCTAssertFalse(queue.state.canCapture)
        XCTAssertEqual(queue.state.pendingCount, 3)
        XCTAssertNil(queue.beginCapture(), "Bound the burst instead of accumulating unbounded data")
        for index in 1...3 {
            await processor.waitUntilStarted(index)
            let jobs = await processor.startedJobs
            XCTAssertEqual(jobs.count, index, "Never process the next photo before the current save finishes")
            await processor.completeFirst(.saved)
        }
        await fulfillment(of: [drained], timeout: 3)
        let jobs = await processor.startedJobs
        XCTAssertEqual(jobs.map(\.parameters.contrast), [10, 20, 30])
        XCTAssertEqual(jobs.map { Array($0.original) }, [[1], [2], [3]])
        let peak = await processor.peakConcurrentJobs
        XCTAssertEqual(peak, 1)
        XCTAssertTrue(queue.state.canCapture)
        XCTAssertEqual(queue.state.bufferedBytes, 0)
    }

    @MainActor
    func testPhotoQueueRecoversAfterFailureAndMemoryWarning() async throws {
        let processor = ControlledPhotoProcessor()
        let queue = PhotoProcessingQueue { job in await processor.process(job) }
        let failed = expectation(description: "Save failure reported")
        let drained = expectation(description: "Queue continues after failed photo")
        queue.onFailure = { _ in failed.fulfill() }
        queue.onStateChange = { state in
            if state.pendingCount == 0 { drained.fulfill() }
        }
        for index in 1...2 {
            let reservation = try XCTUnwrap(queue.beginCapture())
            queue.finishCapture(reservation, original: Data([UInt8(index)]), parameters: .initialAA)
        }
        queue.handleMemoryWarning()
        XCTAssertFalse(queue.state.canCapture)
        await processor.waitUntilStarted(1)
        await processor.completeFirst(.failed(.saveFailed))
        await processor.waitUntilStarted(2)
        XCTAssertFalse(queue.state.canCapture, "Pressure blocks admission until accepted work drains")
        await processor.completeFirst(.saved)
        await fulfillment(of: [failed, drained], timeout: 3)
        XCTAssertTrue(queue.state.canCapture)
    }

    @MainActor
    func testPhotoQueueReleasesCaptureFailureAndStopsAdmissionAtByteLimit() async throws {
        let processor = ControlledPhotoProcessor()
        let queue = PhotoProcessingQueue(byteAdmissionLimit: 4) { job in await processor.process(job) }
        let cancelled = try XCTUnwrap(queue.beginCapture())
        queue.cancelCapture(cancelled)
        XCTAssertTrue(queue.state.canCapture)
        let reservation = try XCTUnwrap(queue.beginCapture())
        let drained = expectation(description: "Large photo saved without dropping it")
        queue.onStateChange = { state in if state.pendingCount == 0 { drained.fulfill() } }
        queue.finishCapture(reservation, original: Data(repeating: 1, count: 5), parameters: .initialAA)
        XCTAssertFalse(queue.state.canCapture)
        XCTAssertEqual(queue.state.bufferedBytes, 5)
        await processor.waitUntilStarted(1)
        await processor.completeFirst(.saved)
        await fulfillment(of: [drained], timeout: 3)
        XCTAssertTrue(queue.state.canCapture)
    }
}

private actor ControlledPhotoProcessor {
    private(set) var startedJobs: [PhotoProcessingJob] = []
    private(set) var peakConcurrentJobs = 0
    private var activeJobs = 0
    private var completions: [CheckedContinuation<PhotoProcessingOutcome, Never>] = []
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func process(_ job: PhotoProcessingJob) async -> PhotoProcessingOutcome {
        startedJobs.append(job)
        activeJobs += 1
        peakConcurrentJobs = max(peakConcurrentJobs, activeJobs)
        let outcome = await withCheckedContinuation { continuation in
            completions.append(continuation)
            let ready = startWaiters.filter { $0.0 <= startedJobs.count }
            startWaiters.removeAll { $0.0 <= startedJobs.count }
            ready.forEach { $0.1.resume() }
        }
        activeJobs -= 1
        return outcome
    }

    func waitUntilStarted(_ count: Int) async {
        if startedJobs.count >= count { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func completeFirst(_ outcome: PhotoProcessingOutcome) {
        completions.removeFirst().resume(returning: outcome)
    }
}
