import AVFoundation
import Foundation

enum CameraLens: String, CaseIterable, Identifiable, Sendable {
    case ultraWide
    case wide
    case telephoto

    var id: String { rawValue }

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: .builtInUltraWideCamera
        case .wide: .builtInWideAngleCamera
        case .telephoto: .builtInTelephotoCamera
        }
    }

    var label: String {
        switch self {
        case .ultraWide: "0.5×"
        case .wide: "1×"
        case .telephoto: "4×"
        }
    }

    var name: String {
        switch self {
        case .ultraWide: "Сверхширокая"
        case .wide: "Основная"
        case .telephoto: "Телефото"
        }
    }
}

final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "monocamera.session", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "monocamera.video", qos: .userInteractive)
    private let renderer: MetalPreviewRenderer
    private var captureDevice: AVCaptureDevice?
    private var captureInput: AVCaptureDeviceInput?
    private var devicesByLens: [CameraLens: AVCaptureDevice] = [:]
    private var configured = false
    private var wantsRunning = false
    private var captures: [Int64: PhotoDelegate] = [:]
    private var histogramFrames = 0
    private var exposureLocked = false
    private var pendingExposureRelock: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    var onStateChange: ((Bool) -> Void)?
    var onExposureRange: ((ClosedRange<Float>) -> Void)?
    var onLensesAvailable: (([CameraLens], CameraLens) -> Void)?
    var onHistogram: (([[Float]]) -> Void)?
    @MainActor private var pendingExposureUpdate: DispatchWorkItem?

    init(renderer: MetalPreviewRenderer) {
        self.renderer = renderer
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                            object: session, queue: nil) { [weak self] _ in
            DispatchQueue.main.async { self?.onStateChange?(false) }
        })
        for name in [AVCaptureSession.interruptionEndedNotification, AVCaptureSession.runtimeErrorNotification] {
            observers.append(center.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                self?.resumeAfterInterruption()
            })
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func start(completion: @escaping (Error?) -> Void) {
        sessionQueue.async {
            self.wantsRunning = true
            if !self.configured {
                do {
                    try self.configure()
                    self.configured = true
                } catch {
                    DispatchQueue.main.async { completion(error) }
                    return
                }
            }
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { completion(self.session.isRunning ? nil : CameraError.unavailable) }
        }
    }

    func stop() {
        sessionQueue.async {
            self.wantsRunning = false
            self.exposureLocked = false
            self.pendingExposureRelock?.cancel()
            self.pendingExposureRelock = nil
            if self.session.isRunning { self.session.stopRunning() }
            self.restoreAutomaticFocusAndExposure()
        }
    }

    func focusAndExpose(at point: CGPoint, lock: Bool, completion: @escaping (Error?) -> Void) {
        sessionQueue.async {
            guard self.session.isRunning, let device = self.captureDevice else {
                DispatchQueue.main.async { completion(CameraError.unavailable) }
                return
            }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                guard device.isFocusPointOfInterestSupported,
                      device.isExposurePointOfInterestSupported,
                      device.isFocusModeSupported(.autoFocus),
                      device.isExposureModeSupported(lock ? .autoExpose : .continuousAutoExposure) else {
                    DispatchQueue.main.async { completion(CameraError.configurationFailed) }
                    return
                }
                device.focusPointOfInterest = point
                device.exposurePointOfInterest = point
                device.focusMode = .autoFocus
                device.exposureMode = lock ? .autoExpose : .continuousAutoExposure
                self.pendingExposureRelock?.cancel()
                self.pendingExposureRelock = nil
                self.exposureLocked = lock
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    private func restoreAutomaticFocusAndExposure() {
        guard let device = captureDevice else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
        } catch {
            NSLog("Could not restore automatic focus and exposure: %@", String(describing: error))
        }
    }

    @MainActor
    func setExposureBias(_ bias: Float) {
        pendingExposureUpdate?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let device = self.captureDevice else { return }
            let value = min(device.maxExposureTargetBias, max(device.minExposureTargetBias, bias))
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(value, completionHandler: nil)
                if self.exposureLocked,
                   device.isExposureModeSupported(.continuousAutoExposure),
                   device.isExposureModeSupported(.autoExpose) {
                    // Meter with the new EV while dragging, then return to one-shot exposure.
                    device.exposureMode = .continuousAutoExposure
                    self.pendingExposureRelock?.cancel()
                    let relock = DispatchWorkItem { [weak self, weak device] in
                        guard let self, let device, self.exposureLocked,
                              self.captureDevice === device else { return }
                        do {
                            try device.lockForConfiguration()
                            device.exposureMode = .autoExpose
                            device.unlockForConfiguration()
                        } catch {
                            NSLog("Exposure relock failed: %@", String(describing: error))
                        }
                    }
                    self.pendingExposureRelock = relock
                    self.sessionQueue.asyncAfter(deadline: .now() + .milliseconds(180), execute: relock)
                }
                device.unlockForConfiguration()
            } catch {
                NSLog("Exposure adjustment failed: %@", String(describing: error))
            }
        }
        pendingExposureUpdate = work
        // Coalesce slider changes so the capture session does not queue every intermediate value.
        sessionQueue.asyncAfter(deadline: .now() + .milliseconds(24), execute: work)
    }

    private func resumeAfterInterruption() {
        sessionQueue.async {
            guard self.wantsRunning else { return }
            if !self.session.isRunning { self.session.startRunning() }
            let ready = self.session.isRunning
            DispatchQueue.main.async { self.onStateChange?(ready) }
        }
    }

    func capture(completion: @escaping (Result<Data, Error>) -> Void) {
        sessionQueue.async {
            guard self.session.isRunning else {
                DispatchQueue.main.async { completion(.failure(CameraError.unavailable)) }
                return
            }
            let format: [String: Any]
            if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                format = [AVVideoCodecKey: AVVideoCodecType.hevc]
            } else {
                format = [AVVideoCodecKey: AVVideoCodecType.jpeg]
            }
            let settings = AVCapturePhotoSettings(format: format)
            settings.photoQualityPrioritization = .balanced
            let identifier = settings.uniqueID
            let delegate = PhotoDelegate(completion: completion) { [weak self] in
                self?.sessionQueue.async { self?.captures.removeValue(forKey: identifier) }
            }
            self.captures[identifier] = delegate
            self.photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    func switchLens(to lens: CameraLens, completion: @escaping (Error?) -> Void) {
        sessionQueue.async {
            guard self.captures.isEmpty,
                  let device = self.devicesByLens[lens],
                  let previousInput = self.captureInput else {
                DispatchQueue.main.async { completion(CameraError.unavailable) }
                return
            }
            guard previousInput.device.uniqueID != device.uniqueID else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            do {
                let newInput = try AVCaptureDeviceInput(device: device)
                let range = try self.configureAutomaticFocusAndExposure(for: device)
                self.session.beginConfiguration()
                self.session.removeInput(previousInput)
                guard self.session.canAddInput(newInput) else {
                    self.session.addInput(previousInput)
                    self.session.commitConfiguration()
                    throw CameraError.configurationFailed
                }
                self.session.addInput(newInput)
                self.session.commitConfiguration()
                self.pendingExposureRelock?.cancel()
                self.pendingExposureRelock = nil
                self.exposureLocked = false
                self.captureInput = newInput
                self.captureDevice = device
                self.applyPortraitRotation()
                self.renderer.clear()
                DispatchQueue.main.async {
                    self.onExposureRange?(range)
                    completion(nil)
                }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    private func configure() throws {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: CameraLens.allCases.map(\.deviceType), mediaType: .video, position: .back
        )
        devicesByLens = Dictionary(uniqueKeysWithValues: CameraLens.allCases.compactMap { lens in
            discovery.devices.first(where: { $0.deviceType == lens.deviceType }).map { (lens, $0) }
        })
        guard let device = devicesByLens[.wide] else {
            throw CameraError.unavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        captureDevice = device
        captureInput = input
        let range = try configureAutomaticFocusAndExposure(for: device)
        DispatchQueue.main.async {
            self.onExposureRange?(range)
            self.onLensesAvailable?(CameraLens.allCases.filter { self.devicesByLens[$0] != nil }, .wide)
        }
        let video = AVCaptureVideoDataOutput()
        video.alwaysDiscardsLateVideoFrames = true
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        video.setSampleBufferDelegate(self, queue: videoQueue)

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(video), session.canAddOutput(photoOutput) else {
            throw CameraError.configurationFailed
        }
        session.addInput(input)
        session.addOutput(video)
        session.addOutput(photoOutput)
        applyPortraitRotation()
    }

    private func configureAutomaticFocusAndExposure(for device: AVCaptureDevice) throws -> ClosedRange<Float> {
        if device.isExposureModeSupported(.continuousAutoExposure) ||
            device.isFocusModeSupported(.continuousAutoFocus) {
            try device.lockForConfiguration()
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.unlockForConfiguration()
        }
        let lower = max(-2, device.minExposureTargetBias)
        let upper = min(2, device.maxExposureTargetBias)
        return lower <= upper ? lower...upper : 0...0
    }

    private func applyPortraitRotation() {
        if let connection = session.outputs.compactMap({ $0 as? AVCaptureVideoDataOutput }).first?.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        if let connection = photoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        renderer.submit(pixelBuffer)
        histogramFrames += 1
        if histogramFrames >= 15 {
            histogramFrames = 0
            let histogram = Self.histogram(of: pixelBuffer)
            DispatchQueue.main.async { self.onHistogram?(histogram) }
        }
    }

    private static func histogram(of buffer: CVPixelBuffer) -> [[Float]] {
        let bins = 64
        var counts = Array(repeating: Array(repeating: Float(0), count: bins), count: 4)
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return counts }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return counts }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in stride(from: 0, to: height, by: max(1, height / 96)) {
            for x in stride(from: 0, to: width, by: max(1, width / 128)) {
                let offset = y * bytesPerRow + x * 4
                let b = Int(pixels[offset])
                let g = Int(pixels[offset + 1])
                let r = Int(pixels[offset + 2])
                let luma = (54 * r + 183 * g + 19 * b) / 256
                counts[0][min(bins - 1, luma * bins / 256)] += 1
                counts[1][min(bins - 1, r * bins / 256)] += 1
                counts[2][min(bins - 1, g * bins / 256)] += 1
                counts[3][min(bins - 1, b * bins / 256)] += 1
            }
        }
        return counts.map { channel in
            let peak = max(1, channel.max() ?? 1)
            return channel.map { sqrtf($0 / peak) }
        }
    }
}

private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Result<Data, Error>) -> Void
    private let finished: () -> Void
    private var delivered = false

    init(completion: @escaping (Result<Data, Error>) -> Void, finished: @escaping () -> Void) {
        self.completion = completion
        self.finished = finished
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error { deliver(.failure(error)); return }
        guard let data = photo.fileDataRepresentation() else {
            deliver(.failure(CameraError.invalidPhoto))
            return
        }
        deliver(.success(data))
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        if !delivered { deliver(.failure(error ?? CameraError.invalidPhoto)) }
        finished()
    }

    private func deliver(_ result: Result<Data, Error>) {
        guard !delivered else { return }
        delivered = true
        completion(result)
    }
}
