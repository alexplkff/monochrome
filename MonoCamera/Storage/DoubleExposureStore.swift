import Foundation
import ImageIO

enum ExposureRecordStage: String, Codable, Sendable { case waiting, pending, failed, abandoned }

struct ExposureRecord: Codable, Identifiable, Sendable {
    var id: UUID
    var imported: Bool
    var stage: ExposureRecordStage = .waiting
    var firstSaved: Bool
    var secondSaved = false
    var resultSaved = false
    var settings: DoubleExposureSettings
    var parameters: FilterParameters?
    var grainSeed: UInt32 = UInt32.random(in: 0...0x00FF_FFFF)
    var firstBytes: Int
    var secondBytes = 0
    var lastError: String?
}

struct ExposureJob: Sendable {
    let id: UUID
    let originalOnly: Bool
    let bufferedBytes: Int
}

struct ExposureStoreState: Codable, Sendable {
    var enabled = false
    var settings = DoubleExposureSettings()
    var activeID: UUID?
    var records: [ExposureRecord] = []
}

// Only compressed source files and small metadata are durable. No full-size bitmap
// lives in this store. All disk work is isolated from the main actor.
actor DoubleExposureStore {
    private let directory: URL
    private var state: ExposureStoreState

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                               in: .userDomainMask)[0]
            .appendingPathComponent("MonoCamera/double-exposure", isDirectory: true)
        let metadata = self.directory.appendingPathComponent("state.json")
        var loaded = (try? Data(contentsOf: metadata)).flatMap {
            try? JSONDecoder().decode(ExposureStoreState.self, from: $0)
        } ?? ExposureStoreState()
        // A terminated worker is never treated as a completed composition.
        for i in loaded.records.indices where loaded.records[i].stage == .pending {
            loaded.records[i].stage = .failed
            loaded.records[i].lastError = "Сохранение прервано. Повторите запись композиции."
        }
        self.state = loaded
    }

    func snapshot() -> ExposureStoreState { state }
    func record(_ id: UUID) throws -> ExposureRecord {
        guard let record = state.records.first(where: { $0.id == id }) else { throw CameraError.invalidPhoto }
        return record
    }
    func sourceURL(_ id: UUID, second: Bool = false) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent(second ? "second.image" : "first.image")
    }
    func source(_ id: UUID, second: Bool = false) throws -> Data {
        try Data(contentsOf: sourceURL(id, second: second), options: .mappedIfSafe)
    }

    func setEnabled(_ enabled: Bool) throws {
        state.enabled = enabled
        try persist()
    }
    func setSettings(_ settings: DoubleExposureSettings) throws {
        state.settings = settings
        if let id = state.activeID, let i = state.records.firstIndex(where: { $0.id == id }) {
            state.records[i].settings = settings
        }
        try persist()
    }

    func begin(first data: Data, imported: Bool) throws -> ExposureRecord {
        guard state.activeID == nil, state.records.count < 3 else { throw CameraError.exposureQueueFull }
        try validate(data)
        let record = ExposureRecord(id: UUID(), imported: imported, firstSaved: imported,
                                    settings: state.settings, firstBytes: data.count)
        let folder = directory.appendingPathComponent(record.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: sourceURL(record.id), options: .atomic)
        state.records.append(record)
        state.activeID = record.id
        do { try persist() }
        catch { state.records.removeAll { $0.id == record.id }; state.activeID = nil; throw error }
        return record
    }

    func finish(second data: Data, parameters: FilterParameters,
                settings: DoubleExposureSettings) throws -> ExposureJob {
        guard let id = state.activeID, let i = state.records.firstIndex(where: { $0.id == id }) else {
            throw CameraError.invalidPhoto
        }
        try validate(data)
        try data.write(to: sourceURL(id, second: true), options: .atomic)
        let previous = state
        state.records[i].secondBytes = data.count
        state.records[i].parameters = parameters
        state.records[i].settings = settings
        state.records[i].stage = .pending
        state.records[i].lastError = nil
        state.activeID = nil
        do { try persist() } catch { state = previous; throw error }
        return ExposureJob(id: id, originalOnly: false,
                           bufferedBytes: state.records[i].firstBytes + data.count)
    }

    func retry(_ id: UUID) throws -> ExposureJob {
        let record = try record(id)
        guard record.stage != .pending else { throw CameraError.exposureQueueFull }
        let originalOnly = record.secondBytes == 0
        try update(id) {
            if !originalOnly { $0.stage = .pending }
            $0.lastError = nil
        }
        return ExposureJob(id: id, originalOnly: originalOnly,
                           bufferedBytes: record.firstBytes + record.secondBytes)
    }

    func markSaved(_ id: UUID, component: Int) throws {
        try update(id) {
            switch component {
            case 0: $0.firstSaved = true
            case 1: $0.secondSaved = true
            default: $0.resultSaved = true
            }
            $0.lastError = nil
        }
        let record = try record(id)
        if record.stage == .abandoned && record.firstSaved { try remove(id) }
    }
    func complete(_ id: UUID) throws {
        guard let record = state.records.first(where: { $0.id == id }) else { return }
        guard record.firstSaved && record.secondSaved && record.resultSaved else { throw CameraError.saveFailed }
        try remove(id)
    }
    func markFailed(_ id: UUID, originalOnly: Bool, message: String) throws {
        try update(id) {
            if !originalOnly { $0.stage = .failed }
            $0.lastError = message
        }
    }

    func cancelActive() throws {
        guard let id = state.activeID else { return }
        let record = try record(id)
        if record.firstSaved { try remove(id) }
        else {
            let previous = state
            state.activeID = nil
            if let i = state.records.firstIndex(where: { $0.id == id }) { state.records[i].stage = .abandoned }
            do { try persist() } catch { state = previous; throw error }
        }
    }
    func discardFailed(_ id: UUID) throws {
        guard try record(id).stage == .failed else { return }
        try remove(id)
    }

    private func remove(_ id: UUID) throws {
        let previous = state
        state.records.removeAll { $0.id == id }
        if state.activeID == id { state.activeID = nil }
        do { try persist() } catch { state = previous; throw error }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString))
    }
    private func update(_ id: UUID, _ body: (inout ExposureRecord) -> Void) throws {
        guard let i = state.records.firstIndex(where: { $0.id == id }) else { throw CameraError.invalidPhoto }
        let previous = state
        body(&state.records[i])
        do { try persist() } catch { state = previous; throw error }
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: directory.appendingPathComponent("state.json"), options: .atomic)
    }
    private func validate(_ data: Data) throws {
        guard data.count <= 64 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20000, height <= 20000,
              Int64(width) * Int64(height) <= 100_000_000 else { throw CameraError.invalidPhoto }
    }
}

enum ExposureProcessor {
    // A serial caller is required (the shared bounded PhotoProcessingQueue). Receipts
    // are durable after each successful write; retries only write missing resources.
    static func process(_ job: ExposureJob, store: DoubleExposureStore,
                        render: @Sendable (Data, Data, FilterParameters, DoubleExposureSettings, UInt32) throws -> Data,
                        save: @Sendable (Data) async -> Bool) async -> PhotoProcessingOutcome {
        do {
            var record = try await store.record(job.id)
            if !record.firstSaved {
                let first = try await store.source(job.id)
                if await save(first) {
                    try await store.markSaved(job.id, component: 0)
                    record.firstSaved = true
                }
            }
            if job.originalOnly {
                if record.firstSaved { return .saved }
                throw CameraError.saveFailed
            }
            if !record.secondSaved {
                let second = try await store.source(job.id, second: true)
                if await save(second) {
                    try await store.markSaved(job.id, component: 1)
                    record.secondSaved = true
                }
            }
            if !record.resultSaved {
                guard let parameters = record.parameters else { throw CameraError.invalidPhoto }
                let first = try await store.source(job.id)
                let second = try await store.source(job.id, second: true)
                let jpeg = try autoreleasepool {
                    try render(first, second, parameters, record.settings, record.grainSeed)
                }
                if await save(jpeg) {
                    try await store.markSaved(job.id, component: 2)
                    record.resultSaved = true
                }
            }
            guard record.firstSaved && record.secondSaved && record.resultSaved else {
                throw CameraError.saveFailed
            }
            try await store.complete(job.id)
            return .saved
        } catch {
            let failure = (error as? CameraError) ?? .saveFailed
            try? await store.markFailed(job.id, originalOnly: job.originalOnly,
                                        message: failure.localizedDescription)
            return .failed(failure)
        }
    }
}
