import AVFoundation
import Foundation
import UIKit

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

    let renderer: MetalPreviewRenderer?
    private let controller: CameraController?
    private let repository: PresetRepository
    private let photoQueue: PhotoProcessingQueue
    private var saveBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var starting = false
    private var focusRequest = 0

    var canShutter: Bool { cameraReady && !isCapturing && !isSwitchingLens && !isSaveQueueFull }

    init() {
        let repository = PresetRepository()
        self.repository = repository
        self.presets = repository.state.presets.sorted(by: { $0.number < $1.number })
        self.selectedNumber = repository.state.selectedNumber
        self.draft = repository.selected.parameters
        let renderer = MetalPreviewRenderer()
        self.renderer = renderer
        self.controller = renderer.map(CameraController.init(renderer:))
        self.photoQueue = PhotoProcessingQueue { [engine = renderer?.engine] job in
            guard let engine else { return .failed(.unavailable) }
            return await PhotoLibraryService.process(job, engine: engine)
        }
        self.photoQueue.onStateChange = { [weak self] state in
            guard let self else { return }
            self.isCapturing = state.isCapturing
            self.pendingPhotoCount = state.pendingCount
            self.isSaveQueueFull = !state.hasCapacity
            self.updateSaveBackgroundTask(hasPendingPhotos: state.pendingCount > 0)
        }
        self.photoQueue.onFailure = { [weak self] error in self?.show(error) }
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
        renderer?.update(parameters: draft, compare: pressed, showsGrain: grainPreviewEnabled)
    }

    func shutter() {
        guard canShutter, let controller, let reservation = photoQueue.beginCapture() else { return }
        let snapshot = draft
        controller.capture { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.photoQueue.cancelCapture(reservation)
                self.show(error)
            case .success(let original):
                self.photoQueue.finishCapture(reservation, original: original, parameters: snapshot)
            }
        }
    }

    func handleMemoryWarning() { photoQueue.handleMemoryWarning() }

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
        renderer?.update(parameters: draft, compare: false, showsGrain: grainPreviewEnabled)
    }

    private func show(_ error: Error) {
        errorMessage = error.localizedDescription
        showsError = true
    }
}
