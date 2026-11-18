import Foundation

enum CameraError: LocalizedError {
    case permissionDenied
    case unavailable
    case configurationFailed
    case invalidPhoto
    case photoProcessingFailed
    case libraryPermissionDenied
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Разрешите доступ к камере в настройках iPhone."
        case .unavailable: "Камера сейчас недоступна."
        case .configurationFailed: "Не удалось настроить камеру."
        case .invalidPhoto, .photoProcessingFailed: "Не удалось обработать снимок."
        case .libraryPermissionDenied: "Разрешите добавление фото в медиатеку."
        case .saveFailed: "Не удалось сохранить снимки в Фото."
        }
    }
}
