import Foundation
import CoreGraphics

struct FocusPointMapper {
    static func devicePoint(for viewPoint: CGPoint, previewSize: CGSize,
                            frameSize: CGSize) -> CGPoint? {
        guard previewSize.width > 0, previewSize.height > 0,
              frameSize.width > 0, frameSize.height > 0 else { return nil }
        let scale = min(previewSize.width / frameSize.width, previewSize.height / frameSize.height)
        let imageSize = CGSize(width: frameSize.width * scale, height: frameSize.height * scale)
        let imageRect = CGRect(x: (previewSize.width - imageSize.width) / 2,
                               y: (previewSize.height - imageSize.height) / 2,
                               width: imageSize.width, height: imageSize.height)
        guard imageRect.contains(viewPoint) else { return nil }
        let u = (viewPoint.x - imageRect.minX) / imageRect.width
        let v = (viewPoint.y - imageRect.minY) / imageRect.height
        // Portrait buffers are rotated 90°; focus points use the unrotated sensor coordinates.
        return frameSize.height > frameSize.width
            ? CGPoint(x: v, y: 1 - u)
            : CGPoint(x: u, y: v)
    }
}

enum CameraError: LocalizedError, Sendable {
    case permissionDenied
    case unavailable
    case configurationFailed
    case invalidPhoto
    case photoProcessingFailed
    case libraryPermissionDenied
    case saveFailed
    case exposureQueueFull

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Разрешите доступ к камере в настройках iPhone."
        case .unavailable: "Камера сейчас недоступна."
        case .configurationFailed: "Не удалось настроить камеру."
        case .invalidPhoto, .photoProcessingFailed: "Не удалось обработать снимок."
        case .libraryPermissionDenied: "Разрешите добавление фото в медиатеку."
        case .saveFailed: "Не удалось сохранить снимки в Фото."
        case .exposureQueueFull: "Завершите или повторите сохранение предыдущих композиций."
        }
    }
}
