import Foundation

struct FilterPreset: Codable, Equatable, Identifiable, Sendable {
    // 0 is the permanent AA profile; 1...8 are user profiles.
    var number: Int
    var parameters: FilterParameters
    var id: Int { number }
    var label: String { number == 0 ? "AA" : String(number) }
}

struct PresetState: Codable, Sendable {
    var version: Int = 1
    var presets: [FilterPreset] = [FilterPreset(number: 0, parameters: .initialAA)]
    var selectedNumber: Int = 0
}

final class PresetRepository {
    private let url: URL
    private(set) var state: PresetState

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MonoCamera/presets.json")
        if let data = try? Data(contentsOf: self.url),
           let loaded = try? JSONDecoder().decode(PresetState.self, from: data),
           loaded.version == 1,
           loaded.presets.contains(where: { $0.number == 0 }),
           Set(loaded.presets.map(\.number)).count == loaded.presets.count,
           loaded.presets.allSatisfy({ (0...8).contains($0.number) }) {
            var valid = loaded
            if !valid.presets.contains(where: { $0.number == valid.selectedNumber }) {
                valid.selectedNumber = 0
            }
            state = valid
        } else {
            state = PresetState()
        }
    }

    var selected: FilterPreset {
        state.presets.first(where: { $0.number == state.selectedNumber })!
    }

    @discardableResult
    func select(_ number: Int) -> Bool {
        guard state.presets.contains(where: { $0.number == number }) else { return false }
        state.selectedNumber = number
        persist()
        return true
    }

    @discardableResult
    func create() -> FilterPreset? {
        guard let free = (1...8).first(where: { number in
            !state.presets.contains(where: { $0.number == number })
        }) else { return nil }
        let preset = FilterPreset(number: free, parameters: .initialAA)
        state.presets.append(preset)
        state.selectedNumber = free
        persist()
        return preset
    }

    @discardableResult
    func rename(_ old: Int, to new: Int) -> Bool {
        guard old != 0, (1...8).contains(new),
              !state.presets.contains(where: { $0.number == new }),
              let index = state.presets.firstIndex(where: { $0.number == old }) else { return false }
        state.presets[index].number = new
        if state.selectedNumber == old { state.selectedNumber = new }
        persist()
        return true
    }

    @discardableResult
    func delete(_ number: Int) -> Bool {
        guard number != 0, state.presets.contains(where: { $0.number == number }) else { return false }
        state.presets.removeAll(where: { $0.number == number })
        if state.selectedNumber == number { state.selectedNumber = 0 }
        persist()
        return true
    }

    func save(_ parameters: FilterParameters, for number: Int) {
        guard let index = state.presets.firstIndex(where: { $0.number == number }) else { return }
        state.presets[index].parameters = parameters
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            // The UI remains usable; a later successful update can persist the state.
            NSLog("Preset persistence failed: %@", String(describing: error))
        }
    }
}
