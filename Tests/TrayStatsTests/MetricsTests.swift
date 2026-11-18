import Testing

@testable import TrayStats

@Suite("Measuring CPU use between two samples")
struct CPUUsageTests {
    @Test("splits busy time into user and system, counting nice as user")
    func splitsUserAndSystem() {
        let old = CPUTicks(user: 100, system: 50, idle: 800, nice: 0)
        let new = CPUTicks(user: 150, system: 75, idle: 900, nice: 25)

        let usage = cpuUsage(from: old, to: new)

        #expect(usage.user == 0.375)
        #expect(usage.system == 0.125)
        #expect(usage.total == 0.5)
    }

    @Test("keeps measuring when a tick counter wraps around")
    func survivesCounterWrap() {
        let old = CPUTicks(user: UInt32.max - 9, system: 0, idle: 0, nice: 0)
        let new = CPUTicks(user: 10, system: 0, idle: 20, nice: 0)

        let usage = cpuUsage(from: old, to: new)

        #expect(usage.user == 0.5)
    }
}

@Suite("Measuring memory the way Activity Monitor does")
struct MemoryUsageTests {
    @Test("counts app memory without purgeable pages, plus wired and compressed")
    func countsUsedMemory() {
        let pages = MemoryPages(internalPages: 1_000, purgeable: 200, wired: 300, compressed: 100)

        let usage = memoryUsage(pages, pageSize: 16_384, physical: 64 * 1_024 * 1_024)

        #expect(usage.used == 1_200 * 16_384)
        #expect(usage.fraction == 0.29296875)
    }
}

@Suite("Measuring the boot volume")
struct DiskUsageTests {
    @Test("treats space available for important use as free")
    func usesImportantAvailableSpace() {
        let usage = diskUsage(total: 500, available: 200)

        #expect(usage.used == 300)
        #expect(usage.fraction == 0.6)
    }
}

@Suite("Choosing the CPU temperature")
struct CPUTemperatureTests {
    @Test("uses the hottest CPU die sensor")
    func usesHottestDieSensor() {
        let readings = [
            SensorReading(name: "PMU tdie1", celsius: 62.9),
            SensorReading(name: "PMU tdie8", celsius: 64.1),
            SensorReading(name: "PMU tdie8", celsius: 63.4),
        ]

        #expect(hottestDieTemperature(readings) == 64.1)
    }

    @Test("ignores sensors that are not on the CPU die")
    func ignoresOtherSensors() {
        let readings = [
            SensorReading(name: "PMU tdie1", celsius: 55),
            SensorReading(name: "PMU tcal", celsius: 70),
            SensorReading(name: "NAND CH0 temp", celsius: 71),
            SensorReading(name: "gas gauge battery", celsius: 72),
        ]

        #expect(hottestDieTemperature(readings) == 55)
    }

    @Test("ignores die sensors that report an impossible value")
    func ignoresInvalidValues() {
        let readings = [
            SensorReading(name: "PMU tdie1", celsius: -9201.1),
            SensorReading(name: "PMU tdie2", celsius: 9_999),
            SensorReading(name: "PMU tdie3", celsius: 57.8),
        ]

        #expect(hottestDieTemperature(readings) == 57.8)
    }

    @Test("gives no temperature when the Mac has no CPU die sensor")
    func noTemperatureWithoutDieSensor() {
        let readings = [SensorReading(name: "NAND CH0 temp", celsius: 38)]

        #expect(hottestDieTemperature(readings) == nil)
    }
}

@Suite("Ranking processes")
struct ProcessRankingTests {
    @Test("ranks processes by CPU time used since the previous scan")
    func ranksByCPUSincePreviousScan() {
        let previous: [Int32: UInt64] = [1: 1_000, 2: 5_000_000_000, 3: 0]
        let current = [
            ProcessSample(pid: 1, name: "Safari", cpuNanoseconds: 1_000_001_000, footprint: 0),
            ProcessSample(pid: 2, name: "Xcode", cpuNanoseconds: 5_500_000_000, footprint: 0),
            ProcessSample(pid: 3, name: "idle", cpuNanoseconds: 0, footprint: 0),
            ProcessSample(pid: 4, name: "new", cpuNanoseconds: 9_000_000_000, footprint: 0),
        ]

        let top = topByCPU(
            previous: previous, current: current, elapsedNanoseconds: 2_000_000_000, limit: 2)

        #expect(
            top == [
                ProcessValue(name: "Safari", value: 0.5),
                ProcessValue(name: "Xcode", value: 0.25),
            ])
    }

    @Test("ranks processes by memory footprint")
    func ranksByFootprint() {
        let samples = [
            ProcessSample(pid: 1, name: "small", cpuNanoseconds: 0, footprint: 10),
            ProcessSample(pid: 2, name: "large", cpuNanoseconds: 0, footprint: 300),
            ProcessSample(pid: 3, name: "medium", cpuNanoseconds: 0, footprint: 200),
        ]

        let top = topByMemory(samples, limit: 2)

        #expect(top.map(\.name) == ["large", "medium"])
    }

    @Test("converts Apple Silicon CPU time ticks to nanoseconds")
    func convertsTicksToNanoseconds() {
        let timebase = Timebase(numer: 125, denom: 3)

        #expect(timebase.nanoseconds(24_000_000) == 1_000_000_000)
    }
}
