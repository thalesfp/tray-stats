import AppKit
import ServiceManagement
import os

@MainActor
final class TrayController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let openMenuInterval: TimeInterval = 2
    private static let diskInterval: TimeInterval = 60
    private static let rowCount = 5

    private let reader: SystemReader
    private let store: SettingsStore
    private let plugins: [any Plugin]
    private let log = Logger(subsystem: "me.thales.traystats", category: "sampling")

    private var visible: VisibleMetrics
    private var refresh: TimeInterval
    private var readings = Readings()
    private var lastTicks: CPUTicks?
    private var lastDiskRead: Date?
    private var processBaseline: (cpu: [Int32: UInt64], at: UInt64)?
    private var menuOpen = false
    private var pluginTasks: [Task<Void, Never>?]
    private var pluginGenerations: [Int]
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
    private let menu = NSMenu()
    private var pluginItems: [NSMenuItem] = []
    private var pluginMenus: [NSMenu] = []
    private var pluginToggles: [NSMenuItem] = []
    private var metricToggles: [Metric: NSMenuItem] = [:]
    private var refreshChoices: [NSMenuItem] = []
    private let loginToggle = NSMenuItem(
        title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")

    init(reader: SystemReader, store: SettingsStore, plugins: [any Plugin]) {
        store.migratePluginKeys(ids: plugins.map(\.id))

        self.reader = reader
        self.store = store
        self.plugins = plugins
        self.pluginTasks = plugins.map { _ in nil }
        self.pluginGenerations = plugins.map { _ in 0 }
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

        if !plugins.isEmpty { menu.addItem(.separator()) }
        for plugin in plugins {
            // AppKit does not open an empty submenu, so each one always holds a row.
            let submenu = NSMenu()
            submenu.delegate = self
            submenu.autoenablesItems = false
            show(Self.loadingRows, in: submenu)

            let item = NSMenuItem(title: plugin.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            pluginItems.append(item)
            pluginMenus.append(submenu)
            menu.addItem(item)
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

        for (index, plugin) in plugins.enumerated() {
            let toggle = NSMenuItem(
                title: "Show \(plugin.title)", action: #selector(togglePlugin), keyEquivalent: "")
            toggle.target = self
            toggle.tag = index
            pluginToggles.append(toggle)
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

    private static let loadingRows = [PluginRow(name: "Loading…", value: "")]

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
        if let index = pluginMenus.firstIndex(where: { $0 === menu }) {
            openPlugin(index)
            return
        }
        guard menu === self.menu else { return }

        menuOpen = true
        processBaseline = nil

        drawToggles()
        drawPluginItems()
        sample()
        startTimer(every: Self.openMenuInterval)

        let firstScan = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanProcesses() }
        }
        RunLoop.main.add(firstScan, forMode: .common)
        self.firstScan = firstScan
    }

    func menuDidClose(_ menu: NSMenu) {
        if let index = pluginMenus.firstIndex(where: { $0 === menu }) {
            closePlugin(index)
            return
        }
        guard menu === self.menu else { return }

        menuOpen = false
        processBaseline = nil
        for index in plugins.indices where pluginTasks[index] != nil { closePlugin(index) }
        firstScan?.invalidate()
        firstScan = nil

        startTimer(every: refresh)
    }

    private func drawPluginItems() {
        for (index, item) in pluginItems.enumerated() {
            item.isHidden = !store.isShown(plugin: plugins[index].id)
        }
    }

    private func openPlugin(_ index: Int) {
        pluginGenerations[index] += 1
        pluginTasks[index]?.cancel()
        pluginTasks[index] = poll(
            plugins[index], index: index, generation: pluginGenerations[index])
    }

    private func closePlugin(_ index: Int) {
        pluginGenerations[index] += 1
        pluginTasks[index]?.cancel()
        pluginTasks[index] = nil

        show(Self.loadingRows, in: pluginMenus[index])
    }

    /// MainActor tasks do not run while NSMenu tracks events; a .common run loop block does.
    private func poll(_ plugin: any Plugin, index: Int, generation: Int) -> Task<Void, Never> {
        Task.detached { [weak self] in
            while !Task.isCancelled {
                let rows = await plugin.rows()

                RunLoop.main.perform(inModes: [.common]) {
                    MainActor.assumeIsolated {
                        self?.draw(rows, plugin: index, generation: generation)
                    }
                }

                do {
                    try await Task.sleep(for: plugin.refreshInterval)
                } catch {
                    return
                }
            }
        }
    }

    private func draw(_ rows: [PluginRow], plugin index: Int, generation: Int) {
        guard generation == pluginGenerations[index] else { return }

        show(rows.isEmpty ? Self.loadingRows : rows, in: pluginMenus[index])
    }

    /// Reuses the submenu items in place: rebuilding the items of an open submenu drops the
    /// highlight.
    private func show(_ rows: [PluginRow], in submenu: NSMenu) {
        while submenu.numberOfItems > rows.count {
            submenu.removeItem(at: submenu.numberOfItems - 1)
        }
        while submenu.numberOfItems < rows.count { submenu.addItem(NSMenuItem()) }

        for (item, row) in zip(submenu.items, rows) {
            item.attributedTitle = Self.rowTitle(row.name, row.value)
        }
    }

    private func drawToggles() {
        for (metric, toggle) in metricToggles {
            toggle.state = visible.shown.contains(metric) ? .on : .off
            toggle.isEnabled = visible.canToggle(metric)
        }

        for choice in refreshChoices {
            choice.state = choice.representedObject as? TimeInterval == refresh ? .on : .off
        }

        for (index, toggle) in pluginToggles.enumerated() {
            toggle.state = store.isShown(plugin: plugins[index].id) ? .on : .off
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

    @objc private func togglePlugin(_ sender: NSMenuItem) {
        let id = plugins[sender.tag].id
        store.save(plugin: id, shown: !store.isShown(plugin: id))

        drawToggles()
        drawPluginItems()
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
