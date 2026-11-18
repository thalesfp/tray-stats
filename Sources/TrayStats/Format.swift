import Foundation

struct Readings: Equatable {
    var cpu: CPUUsage?
    var memory: ByteUsage?
    var disk: ByteUsage?
    var temperature: Double?
}

enum Format {
    private static let figureSpace = "\u{2007}"

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    static func statusTitle(_ readings: Readings, visible: VisibleMetrics) -> String {
        Metric.allCases
            .filter { visible.shown.contains($0) }
            .map { "\($0.label) \(titleValue($0, readings))" }
            .joined(separator: "  ")
    }

    private static func titleValue(_ metric: Metric, _ readings: Readings) -> String {
        switch metric {
        case .cpu: padded(readings.cpu.map { wholePercent($0.total) }, unit: "%")
        case .memory: padded(readings.memory.map { wholePercent($0.fraction) }, unit: "%")
        case .disk: padded(readings.disk.map { wholePercent($0.fraction) }, unit: "%")
        case .temperature: padded(readings.temperature.map { Int($0.rounded()) }, unit: "°")
        }
    }

    private static func wholePercent(_ fraction: Double) -> Int {
        Int((fraction * 100).rounded())
    }

    private static func padded(_ value: Int?, unit: String) -> String {
        let digits = value.map(String.init) ?? "–"
        let padding = String(repeating: figureSpace, count: max(0, 2 - digits.count))

        return "\(padding)\(digits)\(unit)"
    }

    static func cpuDetail(_ usage: CPUUsage?) -> String {
        guard let usage else { return "CPU: –" }

        return "CPU: \(percent(usage.user)) user, \(percent(usage.system)) system"
    }

    static func memoryDetail(_ usage: ByteUsage?) -> String {
        guard let usage else { return "Memory: –" }

        return "Memory: \(memory(usage.used)) of \(memory(usage.total))"
    }

    static func diskDetail(_ usage: ByteUsage?) -> String {
        guard let usage else { return "Disk: –" }

        let free = ByteCountFormatter.string(
            fromByteCount: Int64(usage.total - usage.used), countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: Int64(usage.total), countStyle: .file)

        return "Disk: \(free) free of \(total)"
    }

    static func temperatureDetail(_ celsius: Double?) -> String {
        guard let celsius else { return "CPU Temperature: –" }

        return "CPU Temperature: \(Int(celsius.rounded())) °C"
    }

    static func memory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    static func processName(_ name: String) -> String {
        clipped(name, limit: 26)
    }

    static func clipped(_ text: String, limit: Int) -> String {
        text.count > limit ? "\(text.prefix(limit - 1))…" : text
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))

        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60)m ago"
        case ..<86400: return "\(seconds / 3600)h ago"
        default: return "\(seconds / 86400)d ago"
        }
    }

    static func processCPU(_ share: Double) -> String {
        String(format: "%.1f%%", share * 100)
    }
}
