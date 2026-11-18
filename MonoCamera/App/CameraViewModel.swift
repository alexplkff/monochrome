import AVFoundation
import Foundation
import UniformTypeIdentifiers

@MainActor
final class CameraViewModel: ObservableObject {
    @Published private(set) var presets: [FilterPreset]
    @Published private(set) var selectedNumber: Int
    @Published private(set) var draft: FilterParameters
    @Published var editorVisible = false
    @Published var errorMessage = ""
    @Published var showsError = false
    @Published private(set) var isCapturing = false
    @Published private(set) var cameraReady = false
    @Published private(set) var exposureBias: Float = 0
    @Published private(set) var exposureRange: ClosedRange<Float> = -2...2

    let renderer: MetalPreviewRenderer?
    private let controller: CameraController?
    private let repository: PresetRepository
    private var starting = false

    init() {
        let repository = PresetRepository()
        self.repository = repository
        self.presets = repository.state.presets.sorted(by: { $0.number < $1.number })
        self.selectedNumber = repository.state.selectedNumber
        self.draft = repository.selected.parameters
        let renderer = MetalPreviewRenderer()
        self.renderer = renderer
        self.controller = renderer.map(CameraController.init(renderer:))
        renderer?.update(parameters: draft, compare: false)
        self.controller?.onStateChange = { [weak self] ready in
            Task { @MainActor in self?.cameraReady = ready }
        }
        self.controller?.onExposureRange = { [weak self] range in
            Task { @MainActor in
                guard let self else { return }
                self.exposureRange = range
                self.updateExposure(self.exposureBias)
            }
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

    func updateExposure(_ value: Float) {
        exposureBias = min(exposureRange.upperBound, max(exposureRange.lowerBound, value))
        controller?.setExposureBias(exposureBias)
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
        renderer?.update(parameters: draft, compare: pressed)
    }

    func shutter() {
        guard cameraReady, !isCapturing, let controller, let renderer else { return }
        isCapturing = true
        let snapshot = draft
        controller.capture { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                Task { @MainActor in self.isCapturing = false; self.show(error) }
            case .success(let original):
                let engine = renderer.engine
                Task.detached(priority: .userInitiated) {
                    let monochrome = try? engine.jpeg(from: original, parameters: snapshot)
                    let permitted = await PhotoLibraryService.requestAddPermission()
                    guard permitted else {
                        await MainActor.run { self.isCapturing = false; self.show(CameraError.libraryPermissionDenied) }
                        return
                    }
                    let originalType: UTType = original.starts(with: [0xFF, 0xD8]) ? .jpeg : .heic
                    // Separate changes retain the successful asset if its partner fails.
                    let savedColor = await PhotoLibraryService.save(original, type: originalType)
                    let savedMono = if let monochrome {
                        await PhotoLibraryService.save(monochrome, type: .jpeg)
                    } else { false }
                    await MainActor.run {
                        self.isCapturing = false
                        if !savedColor && !savedMono { self.show(CameraError.saveFailed) }
                    }
                }
            }
        }
    }

    private func refresh() {
        presets = repository.state.presets.sorted(by: { $0.number < $1.number })
        selectedNumber = repository.state.selectedNumber
        draft = repository.selected.parameters
        publishPreview()
    }

    private func publishPreview() {
        renderer?.update(parameters: draft, compare: false)
    }

    private func show(_ error: Error) {
        errorMessage = error.localizedDescription
        showsError = true
    }
}
