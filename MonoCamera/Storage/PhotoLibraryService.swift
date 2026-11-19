import Photos
import Foundation
import UniformTypeIdentifiers

enum PhotoLibraryService {
    static func process(_ job: PhotoProcessingJob, engine: FilterEngine,
                        exposureStore: DoubleExposureStore? = nil) async -> PhotoProcessingOutcome {
        if let exposure = job.exposure, let exposureStore {
            guard await requestAddPermission() else {
                try? await exposureStore.markFailed(exposure.id, originalOnly: exposure.originalOnly,
                                                    message: CameraError.libraryPermissionDenied.localizedDescription)
                return .failed(.libraryPermissionDenied)
            }
            return await ExposureProcessor.process(exposure, store: exposureStore, render: { first, second, params, settings, seed in
                try engine.jpeg(from: second, parameters: params, grainSeed: seed,
                                firstExposure: first, exposureSettings: settings)
            }, save: { data in
                await save(data, type: data.starts(with: [0xFF, 0xD8]) ? .jpeg : .heic)
            })
        }
        guard await requestAddPermission() else { return .failed(.libraryPermissionDenied) }
        // Release full-size Core Image / ImageIO temporaries before awaiting PhotoKit.
        let monochrome = autoreleasepool {
            try? engine.jpeg(from: job.original, parameters: job.parameters, grainSeed: job.grainSeed)
        }
        let originalType: UTType = job.original.starts(with: [0xFF, 0xD8]) ? .jpeg : .heic
        // Separate changes retain the successful asset if its partner fails.
        let savedColor = await save(job.original, type: originalType)
        let savedMono: Bool
        if let monochrome { savedMono = await save(monochrome, type: .jpeg) }
        else { savedMono = false }
        return savedColor || savedMono ? .saved : .failed(.saveFailed)
    }

    static func requestAddPermission() async -> Bool {
        let status = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
        return status == .authorized || status == .limited
    }

    static func save(_ data: Data, type: UTType) async -> Bool {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = type.identifier
                request.addResource(with: .photo, data: data, options: options)
            } completionHandler: { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
