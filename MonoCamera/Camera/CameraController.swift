import AVFoundation
import Foundation

final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "monocamera.session", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "monocamera.video", qos: .userInteractive)
    private let renderer: MetalPreviewRenderer
    private var captureDevice: AVCaptureDevice?
    private var configured = false
    private var wantsRunning = false
    private var captures: [Int64: PhotoDelegate] = [:]
    private var observers: [NSObjectProtocol] = []
    var onStateChange: ((Bool) -> Void)?
    var onExposureRange: ((ClosedRange<Float>) -> Void)?
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
            if self.session.isRunning { self.session.stopRunning() }
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

    private func configure() throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraError.unavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        captureDevice = device
        if device.isExposureModeSupported(.continuousAutoExposure) {
            try device.lockForConfiguration()
            device.exposureMode = .continuousAutoExposure
            device.unlockForConfiguration()
        }
        let lower = max(-2, device.minExposureTargetBias)
        let upper = min(2, device.maxExposureTargetBias)
        let range: ClosedRange<Float> = lower <= upper ? lower...upper : 0...0
        DispatchQueue.main.async { self.onExposureRange?(range) }
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
        if let connection = video.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90 // Portrait capture on the back camera.
        }
        if let connection = photoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        renderer.submit(pixelBuffer)
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
