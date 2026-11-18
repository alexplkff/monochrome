import Photos
import UniformTypeIdentifiers

enum PhotoLibraryService {
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
