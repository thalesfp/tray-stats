struct CPUTicks: Equatable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

struct CPUUsage: Equatable {
    var user: Double
    var system: Double

    var total: Double { user + system }
}

struct MemoryPages: Equatable {
    var internalPages: UInt64
    var purgeable: UInt64
    var wired: UInt64
    var compressed: UInt64
}

struct ByteUsage: Equatable {
    var used: UInt64
    var total: UInt64

    var fraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

struct ProcessSample: Equatable {
    var pid: Int32
    var name: String
    var cpuNanoseconds: UInt64
    var footprint: UInt64
}

struct ProcessValue: Equatable {
    var name: String
    var value: Double
}

struct Timebase: Equatable {
    var numer: UInt32
    var denom: UInt32

    func nanoseconds(_ ticks: UInt64) -> UInt64 {
        ticks * UInt64(numer) / UInt64(denom)
    }
}

func cpuUsage(from old: CPUTicks, to new: CPUTicks) -> CPUUsage {
    let user = Double(new.user &- old.user) + Double(new.nice &- old.nice)
    let system = Double(new.system &- old.system)
    let idle = Double(new.idle &- old.idle)
    let total = user + system + idle

    guard total > 0 else { return CPUUsage(user: 0, system: 0) }

    return CPUUsage(user: user / total, system: system / total)
}

func memoryUsage(_ pages: MemoryPages, pageSize: UInt64, physical: UInt64) -> ByteUsage {
    let app = pages.internalPages - min(pages.purgeable, pages.internalPages)
    let used = (app + pages.wired + pages.compressed) * pageSize

    return ByteUsage(used: min(used, physical), total: physical)
}

func diskUsage(total: UInt64, available: UInt64) -> ByteUsage {
    ByteUsage(used: total - min(available, total), total: total)
}

func topByCPU(
    previous: [Int32: UInt64],
    current: [ProcessSample],
    elapsedNanoseconds: UInt64,
    limit: Int
) -> [ProcessValue] {
    guard elapsedNanoseconds > 0 else { return [] }

    let values = current.compactMap { sample -> ProcessValue? in
        guard let before = previous[sample.pid], sample.cpuNanoseconds >= before else {
            return nil
        }

        let share = Double(sample.cpuNanoseconds - before) / Double(elapsedNanoseconds)

        return ProcessValue(name: sample.name, value: share)
    }

    return Array(values.sorted { $0.value > $1.value }.prefix(limit))
}

func topByMemory(_ samples: [ProcessSample], limit: Int) -> [ProcessValue] {
    let sorted = samples.sorted { $0.footprint > $1.footprint }

    return sorted.prefix(limit).map { ProcessValue(name: $0.name, value: Double($0.footprint)) }
}

struct SensorReading: Equatable {
    var name: String
    var celsius: Double
}

func isDieSensor(_ name: String) -> Bool {
    name.hasPrefix("PMU tdie")
}

// The PMU tdev sensors on an M5 Pro report about -9200 °C, so implausible values are dropped.
private let plausibleCelsius = 0.0...150.0

func hottestDieTemperature(_ readings: [SensorReading]) -> Double? {
    readings
        .filter { isDieSensor($0.name) && plausibleCelsius.contains($0.celsius) }
        .map(\.celsius)
        .max()
}
