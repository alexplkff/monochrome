import Foundation

struct PhotoProcessingJob: Sendable {
    let original: Data
    let parameters: FilterParameters
    let grainSeed: UInt32

    init(original: Data, parameters: FilterParameters, grainSeed: UInt32 = UInt32.random(in: 0...0x00FF_FFFF)) {
        self.original = original
        self.parameters = parameters
        self.grainSeed = grainSeed
    }
}

enum PhotoProcessingOutcome: Sendable {
    case saved
    case failed(CameraError)
}

// Only compressed originals wait in this queue. One worker decodes, renders and saves
// one photo at a time, so a burst never creates several full-size bitmap pipelines.
@MainActor
final class PhotoProcessingQueue {
    struct State {
        let isCapturing: Bool
        let pendingCount: Int
        let bufferedBytes: Int
        let hasCapacity: Bool
        var canCapture: Bool { !isCapturing && hasCapacity }
    }

    private let maxPendingPhotos: Int
    private let byteAdmissionLimit: Int
    private let processor: @Sendable (PhotoProcessingJob) async -> PhotoProcessingOutcome
    private var captureReservation: UUID?
    private var entries: [PhotoProcessingJob] = []
    private var workerRunning = false
    private var memoryPressure = false
    var onStateChange: ((State) -> Void)?
    var onFailure: ((CameraError) -> Void)?

    init(maxPendingPhotos: Int = 3, byteAdmissionLimit: Int = 64 * 1024 * 1024,
         processor: @escaping @Sendable (PhotoProcessingJob) async -> PhotoProcessingOutcome) {
        precondition(maxPendingPhotos > 0 && byteAdmissionLimit > 0)
        self.maxPendingPhotos = maxPendingPhotos
        self.byteAdmissionLimit = byteAdmissionLimit
        self.processor = processor
    }

    var state: State {
        let count = entries.count + (captureReservation == nil ? 0 : 1)
        let bytes = entries.reduce(0) { $0 + $1.original.count }
        return State(isCapturing: captureReservation != nil, pendingCount: count,
                     bufferedBytes: bytes,
                     hasCapacity: !memoryPressure && count < maxPendingPhotos && bytes < byteAdmissionLimit)
    }

    // Reserve before asking AVFoundation for a photo, never discard a photo after capture.
    func beginCapture() -> UUID? {
        guard state.canCapture else { return nil }
        let id = UUID()
        captureReservation = id
        publishState()
        return id
    }

    func cancelCapture(_ id: UUID) {
        guard captureReservation == id else { return }
        captureReservation = nil
        clearPressureIfDrained()
        publishState()
    }

    func finishCapture(_ id: UUID, original: Data, parameters: FilterParameters) {
        guard captureReservation == id else { return }
        entries.append(PhotoProcessingJob(original: original, parameters: parameters))
        captureReservation = nil
        publishState()
        startNextIfNeeded()
    }

    func handleMemoryWarning() {
        // Finish accepted work, but admit no new captures until the queue drains.
        memoryPressure = !entries.isEmpty || captureReservation != nil
        publishState()
    }

    private func startNextIfNeeded() {
        guard !workerRunning, let entry = entries.first else { return }
        workerRunning = true
        let processor = processor
        let worker = Task.detached(priority: .userInitiated) {
            await processor(entry)
        }
        Task { [self] in
            let outcome = await worker.value
            entries.removeFirst()
            workerRunning = false
            clearPressureIfDrained()
            publishState()
            if case .failed(let error) = outcome { onFailure?(error) }
            startNextIfNeeded()
        }
    }

    private func clearPressureIfDrained() {
        if entries.isEmpty && captureReservation == nil { memoryPressure = false }
    }

    private func publishState() { onStateChange?(state) }
}
