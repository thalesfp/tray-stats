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

    func isShown(module id: String) -> Bool {
        defaults.object(forKey: moduleKey(id)) as? Bool ?? true
    }

    func save(module id: String, shown: Bool) {
        defaults.set(shown, forKey: moduleKey(id))
    }

    private func moduleKey(_ id: String) -> String { "show.module.\(id)" }

    func loadRefresh() -> TimeInterval {
        let stored = defaults.double(forKey: Self.refreshKey)

        return Refresh.choices.contains(stored) ? stored : Refresh.standard
    }

    func saveRefresh(_ interval: TimeInterval) {
        defaults.set(interval, forKey: Self.refreshKey)
    }
}
