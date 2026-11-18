import Foundation

enum Metric: String, CaseIterable {
    case cpu
    case memory
    case disk
    case temperature

    var label: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "MEM"
        case .disk: "DSK"
        case .temperature: "TMP"
        }
    }

    var menuTitle: String {
        switch self {
        case .cpu: "Show CPU"
        case .memory: "Show Memory"
        case .disk: "Show Disk"
        case .temperature: "Show Temperature"
        }
    }
}

struct VisibleMetrics: Equatable {
    var shown: Set<Metric>

    func canToggle(_ metric: Metric) -> Bool {
        !(shown == [metric])
    }

    func toggling(_ metric: Metric) -> VisibleMetrics {
        guard canToggle(metric) else { return self }

        var next = shown
        if next.contains(metric) {
            next.remove(metric)
        } else {
            next.insert(metric)
        }

        return VisibleMetrics(shown: next)
    }
}

enum Refresh {
    static let choices: [TimeInterval] = [2, 5, 10, 30]
    static let standard: TimeInterval = 2
}

struct SettingsStore {
    private static let refreshKey = "refreshInterval"

    let defaults: UserDefaults

    private func key(_ metric: Metric) -> String { "show.\(metric.rawValue)" }

    func load() -> VisibleMetrics {
        let shown = Metric.allCases.filter { defaults.object(forKey: key($0)) as? Bool ?? true }

        return VisibleMetrics(shown: Set(shown.isEmpty ? Metric.allCases : shown))
    }

    func save(_ visible: VisibleMetrics) {
        for metric in Metric.allCases {
            defaults.set(visible.shown.contains(metric), forKey: key(metric))
        }
    }

    func isShown(plugin id: String) -> Bool {
        defaults.object(forKey: pluginKey(id)) as? Bool ?? true
    }

    func save(plugin id: String, shown: Bool) {
        defaults.set(shown, forKey: pluginKey(id))
    }

    /// Moves each show.module.<id> setting to show.plugin.<id>. A show.plugin.<id> value that
    /// already exists is kept.
    func migratePluginKeys(ids: [String]) {
        for id in ids {
            let oldKey = "show.module.\(id)"
            guard let value = defaults.object(forKey: oldKey) else { continue }

            if defaults.object(forKey: pluginKey(id)) == nil {
                defaults.set(value, forKey: pluginKey(id))
            }
            defaults.removeObject(forKey: oldKey)
        }
    }

    private func pluginKey(_ id: String) -> String { "show.plugin.\(id)" }

    func loadRefresh() -> TimeInterval {
        let stored = defaults.double(forKey: Self.refreshKey)

        return Refresh.choices.contains(stored) ? stored : Refresh.standard
    }

    func saveRefresh(_ interval: TimeInterval) {
        defaults.set(interval, forKey: Self.refreshKey)
    }
}
