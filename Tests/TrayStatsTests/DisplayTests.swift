import Foundation
import Testing

@testable import TrayStats

@Suite("Drawing the menu bar title")
struct StatusTitleTests {
    private let readings = Readings(
        cpu: CPUUsage(user: 0.08, system: 0.04),
        memory: ByteUsage(used: 68, total: 100),
        disk: ByteUsage(used: 41, total: 100),
        temperature: 64.4
    )

    @Test("shows every visible metric, usage as a percentage and temperature in degrees")
    func showsVisibleMetrics() {
        let title = Format.statusTitle(
            readings, visible: VisibleMetrics(shown: Set(Metric.allCases)))

        #expect(title == "CPU 12%  MEM 68%  DSK 41%  TMP 64°")
    }

    @Test("leaves hidden metrics out")
    func leavesHiddenMetricsOut() {
        let title = Format.statusTitle(readings, visible: VisibleMetrics(shown: [.memory]))

        #expect(title == "MEM 68%")
    }

    @Test("pads single digits so the title keeps its width")
    func padsSingleDigits() {
        let low = Readings(cpu: CPUUsage(user: 0.05, system: 0))

        let title = Format.statusTitle(low, visible: VisibleMetrics(shown: [.cpu]))

        #expect(title == "CPU \u{2007}5%")
    }

    @Test("shows a dash before the first CPU sample")
    func showsDashBeforeFirstSample() {
        let title = Format.statusTitle(Readings(), visible: VisibleMetrics(shown: [.cpu]))

        #expect(title == "CPU \u{2007}–%")
    }

    @Test("pads a single-digit temperature so the title keeps its width")
    func padsSingleDigitTemperature() {
        let cold = Readings(temperature: 8.6)

        let title = Format.statusTitle(cold, visible: VisibleMetrics(shown: [.temperature]))

        #expect(title == "TMP \u{2007}9°")
    }

    @Test("shows a dash when no temperature sensor reads")
    func showsDashWithoutTemperature() {
        let title = Format.statusTitle(Readings(), visible: VisibleMetrics(shown: [.temperature]))

        #expect(title == "TMP \u{2007}–°")
    }
}

@Suite("Drawing the menu details")
struct DetailTests {
    @Test("shows the CPU temperature in degrees Celsius")
    func showsTemperatureInCelsius() {
        #expect(Format.temperatureDetail(63.6) == "CPU Temperature: 64 °C")
    }
}

@Suite("Choosing which metrics the menu bar shows")
struct VisibleMetricsTests {
    @Test("hides a metric while another one stays visible")
    func hidesAMetric() {
        let visible = VisibleMetrics(shown: [.cpu, .disk])

        #expect(visible.toggling(.cpu).shown == [.disk])
    }

    @Test("keeps the last visible metric so the menu bar item never goes empty")
    func keepsTheLastMetric() {
        let visible = VisibleMetrics(shown: [.disk])

        #expect(visible.canToggle(.disk) == false)
        #expect(visible.toggling(.disk).shown == [.disk])
    }

    @Test("remembers hidden metrics across launches")
    func remembersHiddenMetrics() throws {
        let suite = "TrayStatsTests.visibility"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)

        store.save(VisibleMetrics(shown: [.cpu, .memory]))

        #expect(store.load().shown == [.cpu, .memory])
    }

    @Test("remembers the chosen refresh interval and starts at 2 seconds")
    func remembersRefreshInterval() throws {
        let suite = "TrayStatsTests.refresh"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)

        let initial = store.loadRefresh()
        store.saveRefresh(10)

        #expect(initial == 2)
        #expect(store.loadRefresh() == 10)
    }
}
