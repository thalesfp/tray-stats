import AppKit
import ServiceManagement
import os

@MainActor
final class TrayController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let openMenuInterval: TimeInterval = 2
    private static let diskInterval: TimeInterval = 60
    private static let rowCount = 5
    private static let moduleRowCount = 6
    private static let moduleInterval: Duration = .seconds(5)

    private let reader: SystemReader
    private let store: SettingsStore
    private let modules: [any Module]
    private let log = Logger(subsystem: "me.thales.traystats", category: "sampling")

    private var visible: VisibleMetrics
    private var refresh: TimeInterval
    private var readings = Readings()
    private var lastTicks: CPUTicks?
    private var lastDiskRead: Date?
    private var processBaseline: (cpu: [Int32: UInt64], at: UInt64)?
    private var menuOpen = false
    private var menuSession = 0
    private var moduleTasks: [Task<Void, Never>] = []
    private var drawnTitle: String?
    private var temperatureFailed = false

    private var item: NSStatusItem?
    private var timer: Timer?
    private var firstScan: Timer?

    private let cpuDetail = NSMenuItem()
    private let memoryDetail = NSMenuItem()
    private let diskDetail = NSMenuItem()
    private let temperatureDetail = NSMenuItem()
    private let cpuRows = (0..<rowCount).map { _ in NSMenuItem() }
    private let memoryRows = (0..<rowCount).map { _ in NSMenuItem() }
    private var moduleHeaders: [NSMenuItem] = []
    private var moduleRows: [[NSMenuItem]] = []
    private var moduleToggles: [NSMenuItem] = []
    private var metricToggles: [Metric: NSMenuItem] = [:]
    private var refreshChoices: [NSMenuItem] = []
    private let loginToggle = NSMenuItem(
        title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")

    init(reader: SystemReader, store: SettingsStore, modules: [any Module]) {
        self.reader = reader
        self.store = store
        self.modules = modules
        self.visible = store.load()
        self.refresh = store.loadRefresh()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = buildMenu()
        self.item = item

        sample()
        startTimer(every: refresh)
    }

    private func startTimer(every interval: TimeInterval) {
        timer?.invalidate()

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = interval / 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        for detail in [cpuDetail, memoryDetail, diskDetail, temperatureDetail] {
            detail.isEnabled = false
            menu.addItem(detail)
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Top CPU"))
        cpuRows.forEach(menu.addItem)
        menu.addItem(.sectionHeader(title: "Top Memory"))
        memoryRows.forEach(menu.addItem)

        for module in modules {
            let header = NSMenuItem.sectionHeader(title: module.title)
            let rows = (0..<Self.moduleRowCount).map { _ in NSMenuItem() }
            moduleHeaders.append(header)
            moduleRows.append(rows)
            menu.addItem(header)
            rows.forEach(menu.addItem)
        }

        menu.addItem(.separator())
        for metric in Metric.allCases {
            let toggle = NSMenuItem(
                title: metric.menuTitle, action: #selector(toggleMetric), keyEquivalent: "")
            toggle.target = self
            toggle.representedObject = metric.rawValue
            metricToggles[metric] = toggle
            menu.addItem(toggle)
        }

        for (index, module) in modules.enumerated() {
            let toggle = NSMenuItem(
                title: "Show \(module.title)", action: #selector(toggleModule), keyEquivalent: "")
            toggle.target = self
            toggle.tag = index
            moduleToggles.append(toggle)
            menu.addItem(toggle)
        }

        menu.addItem(refreshMenu())

        loginToggle.target = self
        menu.addItem(loginToggle)

        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit Tray Stats", action: #selector(NSApplication.terminate),
                keyEquivalent: "q"))

        return menu
    }

    private func refreshMenu() -> NSMenuItem {
        let submenu = NSMenu()

        refreshChoices = Refresh.choices.map { interval in
            let choice = NSMenuItem(
                title: "\(Int(interval)) seconds", action: #selector(chooseRefresh),
                keyEquivalent: "")
            choice.target = self
            choice.representedObject = interval
            submenu.addItem(choice)
            return choice
        }

        let item = NSMenuItem(title: "Refresh Every", action: nil, keyEquivalent: "")
        item.submenu = submenu

        return item
    }

    private func sample() {
        readings.cpu = readCPU()
        readings.memory = read("memory", reader.memory)
        readings.temperature =
            visible.shown.contains(.temperature) || menuOpen ? readTemperature() : nil

        if lastDiskRead.map({ Date().timeIntervalSince($0) >= Self.diskInterval }) ?? true {
            readings.disk = read("disk", reader.disk)
            lastDiskRead = Date()
        }

        drawStatus()

        if menuOpen {
            drawDetails()
            scanProcesses()
        }
    }

    private func readCPU() -> CPUUsage? {
        guard let ticks = read("cpu", reader.cpuTicks) else {
            lastTicks = nil
            return nil
        }

        let usage = lastTicks.map { cpuUsage(from: $0, to: ticks) }
        lastTicks = ticks

        return usage
    }

    private func readTemperature() -> Double? {
        do {
            let celsius = try reader.cpuTemperature()
            temperatureFailed = false

            return celsius
        } catch {
            if !temperatureFailed {
                log.error(
                    "reading temperature failed, showing a dash until it recovers: \(error, privacy: .public)"
                )
            }
            temperatureFailed = true

            return nil
        }
    }

    private func read<Value>(_ name: String, _ body: () throws -> Value) -> Value? {
        do {
            return try body()
        } catch {
            log.error("reading \(name, privacy: .public) failed: \(error, privacy: .public)")
            return nil
        }
    }

    private func drawStatus() {
        let title = Format.statusTitle(readings, visible: visible)
        guard title != drawnTitle else { return }

        let font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)

        item?.button?.attributedTitle = NSAttributedString(
            string: title, attributes: [.font: font])
        drawnTitle = title
    }

    private func drawDetails() {
        cpuDetail.title = Format.cpuDetail(readings.cpu)
        memoryDetail.title = Format.memoryDetail(readings.memory)
        diskDetail.title = Format.diskDetail(readings.disk)
        temperatureDetail.title = Format.temperatureDetail(readings.temperature)
    }

    private func scanProcesses() {
        let now = DispatchTime.now().uptimeNanoseconds
        let samples = reader.processes()

        let topCPU = processBaseline.map {
            topByCPU(
                previous: $0.cpu, current: samples, elapsedNanoseconds: now - $0.at,
                limit: Self.rowCount)
        }
        processBaseline = (
            Dictionary(
                samples.map { ($0.pid, $0.cpuNanoseconds) }, uniquingKeysWith: { a, _ in a }),
            now
        )

        if let topCPU {
            fill(cpuRows, with: topCPU.map { ($0.name, Format.processCPU($0.value)) })
        } else {
            fill(cpuRows, with: [("Measuring…", "")])
        }

        let topMemory = topByMemory(samples, limit: Self.rowCount)
        fill(memoryRows, with: topMemory.map { ($0.name, Format.memory(UInt64($0.value))) })
    }

    private func fill(_ rows: [NSMenuItem], with values: [(name: String, value: String)]) {
        for (index, row) in rows.enumerated() {
            guard index < values.count else {
                row.isHidden = true
                continue
            }

            row.isHidden = false
            row.attributedTitle = Self.rowTitle(values[index].name, values[index].value)
        }
    }

    private static func rowTitle(_ name: String, _ value: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 320)]

        return NSAttributedString(
            string: "\(Format.processName(name))\t\(value)",
            attributes: [
                .paragraphStyle: style,
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular),
            ])
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        menuSession += 1
        processBaseline = nil

        drawToggles()
        startModules()
        sample()
        startTimer(every: Self.openMenuInterval)

        let firstScan = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanProcesses() }
        }
        RunLoop.main.add(firstScan, forMode: .common)
        self.firstScan = firstScan
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        menuSession += 1
        processBaseline = nil
        for task in moduleTasks { task.cancel() }
        moduleTasks = []
        firstScan?.invalidate()
        firstScan = nil

        startTimer(every: refresh)
    }

    private func startModules() {
        for (index, module) in modules.enumerated() {
            let shown = store.isShown(module: module.id)
            moduleHeaders[index].isHidden = !shown

            guard shown else {
                fill(moduleRows[index], with: [])
                continue
            }

            fill(moduleRows[index], with: [("Loading…", "")])
            moduleTasks.append(poll(module, index: index, session: menuSession))
        }
    }

    /// MainActor tasks do not run while NSMenu tracks events; a .common run loop block does.
    private func poll(_ module: any Module, index: Int, session: Int) -> Task<Void, Never> {
        Task.detached { [weak self] in
            while !Task.isCancelled {
                let rows = await module.rows()

                RunLoop.main.perform(inModes: [.common]) {
                    MainActor.assumeIsolated { self?.draw(rows, module: index, session: session) }
                }

                do {
                    try await Task.sleep(for: Self.moduleInterval)
                } catch {
                    return
                }
            }
        }
    }

    private func draw(_ rows: [ModuleRow], module index: Int, session: Int) {
        guard session == menuSession else { return }

        fill(moduleRows[index], with: rows.map { ($0.name, $0.value) })
    }

    private func drawToggles() {
        for (metric, toggle) in metricToggles {
            toggle.state = visible.shown.contains(metric) ? .on : .off
            toggle.isEnabled = visible.canToggle(metric)
        }

        for choice in refreshChoices {
            choice.state = choice.representedObject as? TimeInterval == refresh ? .on : .off
        }

        for (index, toggle) in moduleToggles.enumerated() {
            toggle.state = store.isShown(module: modules[index].id) ? .on : .off
        }

        loginToggle.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func chooseRefresh(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? TimeInterval else { return }

        refresh = interval
        store.saveRefresh(interval)

        startTimer(every: menuOpen ? Self.openMenuInterval : refresh)
        drawToggles()
    }

    @objc private func toggleMetric(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let metric = Metric(rawValue: raw)
        else { return }

        visible = visible.toggling(metric)
        store.save(visible)

        if metric == .temperature, visible.shown.contains(.temperature) {
            readings.temperature = readTemperature()
        }

        drawStatus()
        drawToggles()
    }

    @objc private func toggleModule(_ sender: NSMenuItem) {
        let id = modules[sender.tag].id
        store.save(module: id, shown: !store.isShown(module: id))

        drawToggles()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp

        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            showFailure("Could not change Launch at Login", error)
        }

        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }

        drawToggles()
    }

    private func showFailure(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription

        NSApplication.shared.activate()
        alert.runModal()
    }
}
