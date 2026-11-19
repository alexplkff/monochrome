import AVFoundation
import Foundation
import UIKit
import CoreImage

@MainActor
final class CameraViewModel: ObservableObject {
    @Published private(set) var presets: [FilterPreset]
    @Published private(set) var selectedNumber: Int
    @Published private(set) var draft: FilterParameters
    @Published var editorVisible = false
    @Published var errorMessage = ""
    @Published var showsError = false
    @Published private(set) var isCapturing = false
    @Published private(set) var pendingPhotoCount = 0
    @Published private(set) var isSaveQueueFull = false
    @Published private(set) var cameraReady = false
    @Published private(set) var exposureBias: Float = 0
    @Published private(set) var exposureRange: ClosedRange<Float> = -2...2
    @Published private(set) var availableLenses: [CameraLens] = [.wide]
    @Published private(set) var selectedLens: CameraLens = .wide
    @Published private(set) var isSwitchingLens = false
    @Published private(set) var histogram = Array(repeating: Array(repeating: Float(0), count: 64), count: 4)
    @Published private(set) var focusIndicatorPoint: CGPoint?
    @Published private(set) var focusLocked = false
    @Published private(set) var grainPreviewEnabled = false
    @Published private(set) var exposureEnabled = false
    @Published private(set) var exposureSettings = DoubleExposureSettings()
    @Published private(set) var hasExposureFirst = false
    @Published private(set) var exposureFailures: [ExposureRecord] = []
    @Published private(set) var exposureStoredCount = 0
    @Published private(set) var isPreparingExposure = true
    @Published var exposureControlsVisible = false

    let renderer: MetalPreviewRenderer?
    private let controller: CameraController?
    private let repository: PresetRepository
    private let photoQueue: PhotoProcessingQueue
    private let exposureStore: DoubleExposureStore
    private var exposureFirst: CIImage?
    private var activeExposureID: UUID?
    private var previewExposureID: UUID?
    private var exposureRefreshGeneration = 0
    private var settingsWriteTask: Task<Void, Never>?
    private var saveBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var starting = false
    private var focusRequest = 0

    var canShutter: Bool {
        cameraReady && !isCapturing && !isSwitchingLens && !isSaveQueueFull && !isPreparingExposure
        && (!exposureEnabled || (hasExposureFirst ? exposureFirst != nil : exposureStoredCount < 3))
    }

    private var exposurePreview: DoubleExposurePreview? {
        guard exposureEnabled, let exposureFirst else { return nil }
        return DoubleExposurePreview(first: exposureFirst, settings: exposureSettings)
    }

    init() {
        let repository = PresetRepository()
        self.repository = repository
        self.presets = repository.state.presets.sorted(by: { $0.number < $1.number })
        self.selectedNumber = repository.state.selectedNumber
        self.draft = repository.selected.parameters
        let renderer = MetalPreviewRenderer()
        self.renderer = renderer
        self.controller = renderer.map(CameraController.init(renderer:))
        let exposureStore = DoubleExposureStore()
        self.exposureStore = exposureStore
        self.photoQueue = PhotoProcessingQueue { [engine = renderer?.engine, exposureStore] job in
            guard let engine else { return .failed(.unavailable) }
            return await PhotoLibraryService.process(job, engine: engine, exposureStore: exposureStore)
        }
        self.photoQueue.onStateChange = { [weak self] state in
            guard let self else { return }
            self.isCapturing = state.isCapturing
            self.pendingPhotoCount = state.pendingCount
            self.isSaveQueueFull = !state.hasCapacity
            self.updateSaveBackgroundTask(hasPendingPhotos: state.pendingCount > 0)
        }
        self.photoQueue.onFailure = { [weak self] error in self?.show(error) }
        self.photoQueue.onCompletion = { [weak self] job, outcome in
            guard let self, job.exposure != nil else { return }
            if case .failed(let error) = outcome { self.show(error) }
            Task { await self.reloadExposureState() }
        }
        renderer?.update(parameters: draft, compare: false)
        self.controller?.onStateChange = { [weak self] ready in
            Task { @MainActor in self?.cameraReady = ready }
        }
        self.controller?.onExposureRange = { [weak self] range in
            Task { @MainActor in
                guard let self else { return }
                self.exposureRange = range
                self.exposureBias = min(range.upperBound, max(range.lowerBound, self.exposureBias))
            }
        }
        self.controller?.onLensesAvailable = { [weak self] lenses, selected in
            Task { @MainActor in
                self?.availableLenses = lenses
                self?.selectedLens = selected
            }
        }
        self.controller?.onHistogram = { [weak self] bins in
            self?.histogram = bins
        }
        Task { await restoreExposure() }
    }

    private func restoreExposure() async {
        let state = await exposureStore.snapshot()
        exposureEnabled = state.enabled
        exposureSettings = state.settings
        await reloadExposureState()
        // Resume a first-original write interrupted before the second capture.
        for record in state.records where !record.imported && !record.firstSaved && record.secondBytes == 0 {
            guard let reservation = photoQueue.beginCapture() else { break }
            let job = ExposureJob(id: record.id, originalOnly: true, bufferedBytes: record.firstBytes)
            photoQueue.finishCapture(reservation, job: PhotoProcessingJob(original: Data(), parameters: .initialAA,
                                                                          exposure: job))
        }
        isPreparingExposure = false
    }

    private func reloadExposureState() async {
        exposureRefreshGeneration += 1
        let generation = exposureRefreshGeneration
        let state = await exposureStore.snapshot()
        guard generation == exposureRefreshGeneration else { return }
        exposureFailures = state.records.filter { $0.stage == .failed || $0.lastError != nil }
        exposureStoredCount = state.records.count
        activeExposureID = state.activeID
        hasExposureFirst = state.activeID != nil
        if state.activeID != previewExposureID {
            exposureFirst = nil
            previewExposureID = nil
            if let id = state.activeID {
                let url = await exposureStore.sourceURL(id)
                do {
                    let image = try await Task.detached(priority: .userInitiated) {
                        try DoubleExposureCompositor.previewImage(at: url)
                    }.value
                    guard generation == exposureRefreshGeneration else { return }
                    exposureFirst = image
                    previewExposureID = id
                } catch {
                    guard generation == exposureRefreshGeneration else { return }
                    show(error)
                }
            }
        }
        publishPreview()
    }

    func setExposureEnabled(_ enabled: Bool) {
        guard !isCapturing, !isPreparingExposure else { return }
        exposureEnabled = enabled
        publishPreview()
        Task {
            do { try await exposureStore.setEnabled(enabled) } catch { show(error) }
        }
    }

    func updateExposureSettings(_ update: (inout DoubleExposureSettings) -> Void) {
        update(&exposureSettings)
        publishPreview()
        let snapshot = exposureSettings
        let previous = settingsWriteTask
        settingsWriteTask = Task {
            await previous?.value
            do { try await exposureStore.setSettings(snapshot) } catch { show(error) }
        }
    }

    func importExposureFirst(_ data: Data) async {
        guard exposureEnabled, !isPreparingExposure, !isCapturing, !hasExposureFirst else { return }
        isPreparingExposure = true
        await settingsWriteTask?.value
        do {
            _ = try await exposureStore.begin(first: data, imported: true)
            await reloadExposureState()
        } catch { show(error) }
        isPreparingExposure = false
    }

    func reportImportError(_ error: Error) { show(error) }

    func cancelExposurePair() {
        guard !isCapturing, !isPreparingExposure else { return }
        isPreparingExposure = true
        Task {
            do { try await exposureStore.cancelActive() } catch { show(error) }
            await reloadExposureState()
            isPreparingExposure = false
        }
    }

    func retryExposure(_ id: UUID) {
        guard !isPreparingExposure, let reservation = photoQueue.beginCapture() else { return }
        isPreparingExposure = true
        Task {
            do {
                let job = try await exposureStore.retry(id)
                photoQueue.finishCapture(reservation, job: PhotoProcessingJob(original: Data(), parameters: .initialAA,
                                                                              exposure: job))
            } catch { photoQueue.cancelCapture(reservation); show(error) }
            await reloadExposureState()
            isPreparingExposure = false
        }
    }

    func discardExposureFailure(_ id: UUID) {
        guard !isPreparingExposure else { return }
        isPreparingExposure = true
        Task {
            do { try await exposureStore.discardFailed(id) } catch { show(error) }
            await reloadExposureState()
            isPreparingExposure = false
        }
    }

    func start() {
        guard !starting, !cameraReady else { return }
        guard let controller else { show(CameraError.unavailable); return }
        starting = true
        Task {
            let permission: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: permission = true
            case .notDetermined: permission = await AVCaptureDevice.requestAccess(for: .video)
            default: permission = false
            }
            guard permission else {
                starting = false
                show(CameraError.permissionDenied)
                return
            }
            controller.start { [weak self] error in
                guard let self else { return }
                self.starting = false
                if let error { self.show(error) } else {
                    self.cameraReady = true
                    controller.setExposureBias(self.exposureBias)
                }
            }
            // Request add-only access before the first capture, while camera startup is in progress.
            _ = await PhotoLibraryService.requestAddPermission()
        }
    }

    func stop() {
        controller?.stop()
        cameraReady = false
        starting = false
        focusRequest += 1
        focusIndicatorPoint = nil
        focusLocked = false
    }

    func focus(at viewPoint: CGPoint, previewSize: CGSize, lock: Bool) {
        guard cameraReady, !isSwitchingLens, !isCapturing,
              let frameSize = renderer?.frameSize, let controller,
              let devicePoint = FocusPointMapper.devicePoint(for: viewPoint,
                                                              previewSize: previewSize,
                                                              frameSize: frameSize) else { return }
        focusRequest += 1
        let request = focusRequest
        controller.focusAndExpose(at: devicePoint, lock: lock) { [weak self] error in
            guard let self, self.focusRequest == request else { return }
            if let error { self.show(error); return }
            self.focusIndicatorPoint = viewPoint
            self.focusLocked = lock
            if !lock {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, self.focusRequest == request, !self.focusLocked else { return }
                    self.focusIndicatorPoint = nil
                }
            }
        }
    }

    func select(_ number: Int) {
        guard repository.select(number) else { return }
        editorVisible = false
        refresh()
    }

    func createPreset() {
        guard repository.create() != nil else { return }
        editorVisible = false
        refresh()
    }

    func rename(_ old: Int, to new: Int) {
        guard repository.rename(old, to: new) else { return }
        editorVisible = false
        refresh()
    }

    func delete(_ number: Int) {
        guard repository.delete(number) else { return }
        editorVisible = false
        refresh()
    }

    func toggleEditor() {
        if editorVisible {
            cancel() // Leaving without Save discards the draft.
        } else {
            draft = repository.selected.parameters
            editorVisible = true
            publishPreview()
        }
    }

    func updateWeight(_ channel: Int, value: Float) {
        draft.setWeight(channel, to: value)
        publishPreview()
    }

    func updateContrast(_ value: Float) {
        draft.contrast = value
        publishPreview()
    }

    func updateGrainBrand(_ brand: GrainBrand) {
        draft.grain.brand = brand
        publishPreview()
    }

    func updateGrainISO(_ value: Float) {
        draft.grain.iso = value.isFinite ? min(3200, max(50, value)) : 400
        publishPreview()
    }

    func updateGrainStrength(_ value: Float) {
        if value > 0 && renderer?.engine.supportsGrain != true {
            show(CameraError.photoProcessingFailed)
            return
        }
        draft.grain.strength = value.isFinite ? min(100, max(0, value)) : 0
        publishPreview()
    }

    func setGrainPreview(_ enabled: Bool) {
        grainPreviewEnabled = enabled
        publishPreview()
    }

    func updateLevels(_ channel: LevelChannel, handle: Int, value: Float) {
        var levels = draft.levels(for: channel)
        levels.set(handle, to: value)
        draft.setLevels(levels, for: channel)
        publishPreview()
    }

    func updateExposure(_ value: Float) {
        exposureBias = min(exposureRange.upperBound, max(exposureRange.lowerBound, value))
        controller?.setExposureBias(exposureBias)
    }

    func selectLens(_ lens: CameraLens) {
        guard cameraReady, !isCapturing, !isSwitchingLens, availableLenses.contains(lens),
              let controller else { return }
        isSwitchingLens = true
        controller.switchLens(to: lens, exposureBias: exposureBias) { [weak self] error in
            guard let self else { return }
            self.isSwitchingLens = false
            if let error {
                self.show(error)
            } else {
                self.selectedLens = lens
            }
        }
    }

    func reset() {
        draft = repository.selected.parameters
        publishPreview()
    }

    func save() {
        repository.save(draft, for: selectedNumber)
        editorVisible = false
        refresh()
    }

    func cancel() {
        editorVisible = false
        draft = repository.selected.parameters
        publishPreview()
    }

    func compare(_ pressed: Bool) {
        renderer?.update(parameters: draft, compare: pressed, showsGrain: grainPreviewEnabled, exposure: exposurePreview)
    }

    func shutter() {
        guard canShutter, let controller, let reservation = photoQueue.beginCapture() else { return }
        let snapshot = draft
        let usingExposure = exposureEnabled
        let firstCapture = !hasExposureFirst
        let settings = exposureSettings
        controller.capture { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.photoQueue.cancelCapture(reservation)
                self.show(error)
            case .success(let original):
                guard usingExposure else {
                    self.photoQueue.finishCapture(reservation, original: original, parameters: snapshot)
                    return
                }
                self.isPreparingExposure = true
                Task {
                    await self.settingsWriteTask?.value
                    do {
                        let job: ExposureJob
                        if firstCapture {
                            let record = try await self.exposureStore.begin(first: original, imported: false)
                            job = ExposureJob(id: record.id, originalOnly: true, bufferedBytes: original.count)
                        } else {
                            job = try await self.exposureStore.finish(second: original, parameters: snapshot,
                                                                      settings: settings)
                        }
                        self.photoQueue.finishCapture(reservation, job: PhotoProcessingJob(original: Data(),
                                                                                           parameters: snapshot,
                                                                                           exposure: job))
                    } catch { self.photoQueue.cancelCapture(reservation); self.show(error) }
                    await self.reloadExposureState()
                    self.isPreparingExposure = false
                }
            }
        }
    }

    func handleMemoryWarning() {
        photoQueue.handleMemoryWarning()
        renderer?.engine.context.clearCaches()
    }

    private func updateSaveBackgroundTask(hasPendingPhotos: Bool) {
        if hasPendingPhotos && saveBackgroundTask == .invalid {
            saveBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save photos") { [weak self] in
                self?.endSaveBackgroundTask()
            }
        } else if !hasPendingPhotos {
            endSaveBackgroundTask()
        }
    }

    private func endSaveBackgroundTask() {
        guard saveBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(saveBackgroundTask)
        saveBackgroundTask = .invalid
    }

    private func refresh() {
        presets = repository.state.presets.sorted(by: { $0.number < $1.number })
        selectedNumber = repository.state.selectedNumber
        draft = repository.selected.parameters
        publishPreview()
    }

    private func publishPreview() {
        renderer?.update(parameters: draft, compare: false, showsGrain: grainPreviewEnabled, exposure: exposurePreview)
    }

    private func show(_ error: Error) {
        errorMessage = error.localizedDescription
        showsError = true
    }
}
