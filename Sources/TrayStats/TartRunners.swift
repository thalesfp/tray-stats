import Foundation
import os

struct TartRunnerConfig: Sendable {
    var tart: String
    var vm: String
    var stateDirectory: URL

    static func standard(home: URL) -> TartRunnerConfig {
        TartRunnerConfig(
            tart: home.appending(path: ".local/bin/tart").path,
            vm: "ci-runner",
            stateDirectory: home.appending(path: "Library/Application Support/ci-runner")
        )
    }
}

struct VMInfo: Equatable, Decodable {
    var running: Bool
    var cpus: Int
    var memoryMegabytes: Int

    private enum CodingKeys: String, CodingKey {
        case running = "Running"
        case cpus = "CPU"
        case memoryMegabytes = "Memory"
    }
}

enum Activity: Equatable {
    case busy(job: String?)
    case idle
}

struct GuestReport: Equatable {
    var activity: Activity
    var memory: ByteUsage?
    var load: Double?
}

struct ControllerState: Equatable {
    var starting: Bool
    var lastActive: Date?
}

struct RunnerStatus: Equatable {
    var vm: Result<VMInfo, CommandFailure>
    var guest: GuestReport?
    var controller: ControllerState?
    var bootFailedUntil: Date?
}

enum GuestProbe {
    static let script = """
        pgrep -qx Runner.Worker; rc=$?
        case $rc in 0) echo state=busy;; 1) echo state=idle;; *) exit $rc;; esac
        echo "lock=$(readlink "$HOME/.ci-job-lock" 2>/dev/null || true)"
        echo "memsize=$(sysctl -n hw.memsize)"
        echo "loadavg=$(sysctl -n vm.loadavg)"
        echo "--- vm_stat"
        vm_stat
        exit 0
        """

    static func parse(_ output: String) -> GuestReport? {
        let lines = output.split(separator: "\n").map(String.init)
        let labels = keyValues(lines.prefix { $0 != "--- vm_stat" })

        let activity: Activity
        switch labels["state"] {
        case "busy":
            let lock = labels["lock"] ?? ""
            activity = .busy(job: lock.isEmpty ? nil : lock)
        case "idle":
            activity = .idle
        default:
            return nil
        }

        let physical = labels["memsize"].flatMap { UInt64($0) }
        let memory = physical.flatMap { physical in
            vmStatPages(lines).map {
                memoryUsage($0.pages, pageSize: $0.pageSize, physical: physical)
            }
        }

        return GuestReport(
            activity: activity, memory: memory, load: labels["loadavg"].flatMap(firstLoad))
    }

    private static func firstLoad(_ text: String) -> Double? {
        text.split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "}" })
            .first
            .flatMap { Double($0) }
    }

    private static func vmStatPages(_ lines: [String]) -> (pages: MemoryPages, pageSize: UInt64)? {
        guard let header = lines.first(where: { $0.contains("page size of") }),
            let pageSize = header.split(separator: " ").compactMap({ UInt64($0) }).first
        else { return nil }

        var counts: [String: UInt64] = [:]
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let digits = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            counts[String(parts[0])] = UInt64(digits)
        }

        guard let anonymous = counts["Anonymous pages"],
            let purgeable = counts["Pages purgeable"],
            let wired = counts["Pages wired down"],
            let compressed = counts["Pages occupied by compressor"]
        else { return nil }

        let pages = MemoryPages(
            internalPages: anonymous, purgeable: purgeable, wired: wired, compressed: compressed)

        return (pages, pageSize)
    }
}

enum ControllerFiles {
    static func parseState(_ text: String) -> ControllerState {
        let values = keyValues(text.split(separator: "\n").map(String.init))
        let startTime = values["START_TIME"].flatMap { Int($0) } ?? 0
        let lastActive = values["LAST_ACTIVE"].flatMap { Int($0) } ?? 0

        return ControllerState(
            starting: startTime > 0,
            lastActive: lastActive > 0 ? Date(timeIntervalSince1970: TimeInterval(lastActive)) : nil
        )
    }

    static func parseBootFailed(_ text: String) -> Date? {
        Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
    }
}

private func keyValues<Lines: Sequence<String>>(_ lines: Lines) -> [String: String] {
    var values: [String: String] = [:]
    for line in lines {
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { continue }

        values[String(parts[0])] = String(parts[1])
    }

    return values
}

enum RunnerRows {
    private static let errorLimit = 40

    static func rows(_ status: RunnerStatus, vm name: String, now: Date) -> [ModuleRow] {
        let info: VMInfo
        switch status.vm {
        case .failure(let failure):
            return [
                ModuleRow(name: "tart", value: Format.clipped(failure.message, limit: errorLimit))
            ]
        case .success(let value):
            info = value
        }

        var rows: [ModuleRow] = []

        if info.running {
            rows.append(ModuleRow(name: name, value: "Running · \(activityLabel(status))"))

            if case .busy(let job?) = status.guest?.activity {
                rows.append(ModuleRow(name: "Job", value: job))
            }

            if let guest = status.guest, let memory = guest.memory {
                rows.append(ModuleRow(name: "Guest", value: guestLabel(memory, load: guest.load)))
            }

            let allocated = Format.memory(UInt64(info.memoryMegabytes) * 1024 * 1024)
            rows.append(ModuleRow(name: "Allocated", value: "\(info.cpus) CPU · \(allocated)"))
        } else {
            rows.append(ModuleRow(name: name, value: "Stopped"))
        }

        if let controller = status.controller {
            let value = controller.lastActive.map { Format.ago($0, now: now) } ?? "Never"
            rows.append(ModuleRow(name: "Last active", value: value))
        }

        if let until = status.bootFailedUntil, until > now {
            rows.append(
                ModuleRow(
                    name: "Boot failed until",
                    value: until.formatted(date: .omitted, time: .shortened)))
        }

        return rows
    }

    private static func activityLabel(_ status: RunnerStatus) -> String {
        switch status.guest?.activity {
        case .busy: "Busy"
        case .idle: "Idle"
        case nil: status.controller?.starting == true ? "Starting" : "Busy/idle unknown"
        }
    }

    private static func guestLabel(_ memory: ByteUsage, load: Double?) -> String {
        let used = "\(Format.memory(memory.used)) of \(Format.memory(memory.total))"
        guard let load else { return used }

        return "\(used) · load \(String(format: "%.1f", load))"
    }
}

struct TartRunnerModule: Module {
    private static let timeout: TimeInterval = 5

    let id = "tartRunners"
    let title = "Tart Runners"

    let config: TartRunnerConfig
    let runner: any CommandRunner
    let readFile: @Sendable (URL) -> String?
    let now: @Sendable () -> Date

    private let log = Logger(subsystem: "me.thales.traystats", category: "tart")

    init(
        config: TartRunnerConfig,
        runner: any CommandRunner,
        readFile: @escaping @Sendable (URL) -> String?,
        now: @escaping @Sendable () -> Date
    ) {
        self.config = config
        self.runner = runner
        self.readFile = readFile
        self.now = now
    }

    func rows() async -> [ModuleRow] {
        RunnerRows.rows(await status(), vm: config.vm, now: now())
    }

    private func status() async -> RunnerStatus {
        let vm = await vmInfo()
        let running = (try? vm.get().running) ?? false
        let guest = running ? await guestReport() : nil

        return RunnerStatus(
            vm: vm,
            guest: guest,
            controller: readFile(config.stateDirectory.appending(path: "state"))
                .map(ControllerFiles.parseState),
            bootFailedUntil: readFile(config.stateDirectory.appending(path: "boot-failed"))
                .flatMap(ControllerFiles.parseBootFailed)
        )
    }

    private func vmInfo() async -> Result<VMInfo, CommandFailure> {
        do {
            let json = try await runner.run(
                config.tart, ["get", config.vm, "--format", "json"], timeout: Self.timeout)

            return .success(try JSONDecoder().decode(VMInfo.self, from: Data(json.utf8)))
        } catch let failure as CommandFailure {
            return .failure(failure)
        } catch {
            return .failure(CommandFailure(message: "\(error)"))
        }
    }

    private func guestReport() async -> GuestReport? {
        do {
            let output = try await runner.run(
                config.tart, ["exec", config.vm, "sh", "-c", GuestProbe.script],
                timeout: Self.timeout)

            guard let report = GuestProbe.parse(output) else {
                log.error("guest probe output unreadable: \(output, privacy: .public)")
                return nil
            }

            return report
        } catch {
            log.error("guest probe failed, showing busy/idle unknown: \(error, privacy: .public)")
            return nil
        }
    }
}
