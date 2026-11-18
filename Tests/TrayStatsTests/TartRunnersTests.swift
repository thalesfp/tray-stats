import Foundation
import Testing

@testable import TrayStats

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private let runningJSON = """
    {"Running": true, "State": "running", "CPU": 12, "Memory": 32768, "OS": "darwin"}
    """

private let stoppedJSON = """
    {"Running": false, "State": "stopped", "CPU": 12, "Memory": 32768, "OS": "darwin"}
    """

private func probeOutput(state: String, lock: String) -> String {
    """
    state=\(state)
    lock=\(lock)
    memsize=8589934592
    loadavg={ 3.14 2.50 1.20 }
    --- vm_stat
    Mach Virtual Memory Statistics: (page size of 16384 bytes)
    Pages free:                                   100000.
    Pages wired down:                              50000.
    Pages purgeable:                               10000.
    Anonymous pages:                              200000.
    Pages occupied by compressor:                  20000.
    """
}

private struct FakeTart: CommandRunner {
    var get: Result<String, CommandFailure>
    var exec: Result<String, CommandFailure>

    func run(_ path: String, _ arguments: [String], timeout: TimeInterval) async throws -> String {
        try (arguments.first == "get" ? get : exec).get()
    }
}

private func module(
    get: Result<String, CommandFailure>,
    exec: Result<String, CommandFailure> = .failure(CommandFailure(message: "not running")),
    files: [String: String] = ["state": "START_TIME=0\nLAST_ACTIVE=\(1_800_000_000 - 180)\n"]
) -> TartRunnerModule {
    TartRunnerModule(
        config: TartRunnerConfig(
            tart: "/tart", vm: "ci-runner", stateDirectory: URL(fileURLWithPath: "/state")),
        runner: FakeTart(get: get, exec: exec),
        readFile: { files[$0.lastPathComponent] },
        now: { now }
    )
}

@Suite("Showing the Tart runner VM")
struct TartRunnersTests {
    @Test("shows the job, guest usage, and allocation of a busy VM")
    func showsBusyVM() async {
        let rows = await module(
            get: .success(runningJSON),
            exec: .success(probeOutput(state: "busy", lock: "simpleiptv-apple"))
        ).rows()

        #expect(
            rows == [
                ModuleRow(name: "ci-runner", value: "Running · Busy"),
                ModuleRow(name: "Job", value: "simpleiptv-apple"),
                ModuleRow(name: "Guest", value: "3.97 GB of 8 GB · load 3.1"),
                ModuleRow(name: "Allocated", value: "12 CPU · 32 GB"),
                ModuleRow(name: "Last active", value: "3m ago"),
            ])
    }

    @Test("hides a stale job lock when no job runs")
    func hidesStaleLock() async {
        let rows = await module(
            get: .success(runningJSON),
            exec: .success(probeOutput(state: "idle", lock: "retrokit"))
        ).rows()

        #expect(rows.first == ModuleRow(name: "ci-runner", value: "Running · Idle"))
        #expect(!rows.contains { $0.name == "Job" })
    }

    @Test("shows only the state and last activity of a stopped VM")
    func showsStoppedVM() async {
        let rows = await module(get: .success(stoppedJSON)).rows()

        #expect(
            rows == [
                ModuleRow(name: "ci-runner", value: "Stopped"),
                ModuleRow(name: "Last active", value: "3m ago"),
            ])
    }

    @Test("shows the tart error when the VM cannot be read")
    func showsTartError() async {
        let rows = await module(
            get: .failure(CommandFailure(message: "not found")), files: [:]
        ).rows()

        #expect(rows == [ModuleRow(name: "tart", value: "not found")])
    }

    @Test("keeps the other rows when the guest probe fails")
    func keepsRowsWhenProbeFails() async {
        let rows = await module(get: .success(runningJSON)).rows()

        #expect(
            rows == [
                ModuleRow(name: "ci-runner", value: "Running · Busy/idle unknown"),
                ModuleRow(name: "Allocated", value: "12 CPU · 32 GB"),
                ModuleRow(name: "Last active", value: "3m ago"),
            ])
    }

    @Test("shows the VM as starting while the controller boots it")
    func showsStarting() async {
        let rows = await module(
            get: .success(runningJSON),
            files: ["state": "START_TIME=\(1_800_000_000 - 20)\nLAST_ACTIVE=0\n"]
        ).rows()

        #expect(rows.first == ModuleRow(name: "ci-runner", value: "Running · Starting"))
        #expect(rows.last == ModuleRow(name: "Last active", value: "Never"))
    }

    @Test("shows when a failed boot stops blocking new starts")
    func showsBootFailure() async {
        let until = now.addingTimeInterval(600)

        let rows = await module(
            get: .success(stoppedJSON),
            files: ["boot-failed": "\(Int(until.timeIntervalSince1970))\n"]
        ).rows()

        #expect(
            rows == [
                ModuleRow(name: "ci-runner", value: "Stopped"),
                ModuleRow(
                    name: "Boot failed until",
                    value: until.formatted(date: .omitted, time: .shortened)),
            ])
    }
}
