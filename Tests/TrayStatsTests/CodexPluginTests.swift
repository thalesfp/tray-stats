import Foundation
import Testing

@testable import TrayStats

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private let realResult = """
    {"rateLimits":{"limitId":"codex","primary":{"usedPercent":21,"windowDurationMins":10080,\
    "resetsAt":1800201600},"secondary":null,"credits":{"hasCredits":false,"unlimited":false,\
    "balance":"0"},"planType":"prolite","rateLimitReachedType":null},\
    "rateLimitResetCredits":{"availableCount":1,"credits":[{"id":"c1","status":"available",\
    "expiresAt":1802592000,"grantedAt":1799000000,"resetType":"codexRateLimits",\
    "title":"Full reset"}]}}
    """

private func rows(_ result: String) throws -> [PluginRow] {
    CodexRows.rows(try CodexReply.parse(Data(result.utf8)), now: now, calendar: utc)
}

private struct FakeCodex: CodexClient {
    var result: Result<Data, CommandFailure>

    func rateLimits() async throws -> Data { try result.get() }
}

@Suite("Showing Codex usage")
struct CodexRowsTests {
    @Test("shows plan, weekly usage, renewal, reset credits and paid credits")
    func showsRealReply() throws {
        #expect(
            try rows(realResult) == [
                PluginRow(name: "Plan", value: "Pro Lite"),
                PluginRow(name: "Week", value: "21% used"),
                PluginRow(name: "Renews", value: "Sun 16:00 (in 2d 8h)"),
                PluginRow(name: "Resets", value: "1 available · expires Feb 14"),
                PluginRow(name: "Credits", value: "0"),
            ])
    }

    @Test("shows both the 5 hour and the weekly window")
    func showsBothWindows() throws {
        let result = """
            {"rateLimits":{"primary":{"usedPercent":40,"windowDurationMins":300,\
            "resetsAt":1800003900},"secondary":{"usedPercent":12.6,"windowDurationMins":10080}}}
            """

        #expect(
            try rows(result) == [
                PluginRow(name: "5 hours", value: "40% used"),
                PluginRow(name: "Renews", value: "09:05 (in 1h 5m)"),
                PluginRow(name: "Week", value: "13% used"),
            ])
    }

    @Test("shows a warning when the limit is reached")
    func showsLimitReached() throws {
        let result = #"{"rateLimits":{"rateLimitReachedType":"rate_limit_reached"}}"#

        #expect(try rows(result) == [PluginRow(name: "Limit reached", value: "Rate limit reached")])
    }

    @Test("labels a window without a length as a limit")
    func labelsWindowWithoutLength() throws {
        let result = #"{"rateLimits":{"primary":{"usedPercent":5}}}"#

        #expect(try rows(result) == [PluginRow(name: "Limit", value: "5% used")])
    }

    @Test("shows None when no reset credit is available")
    func showsNoResets() throws {
        let result = #"{"rateLimits":{},"rateLimitResetCredits":{"availableCount":0,"credits":[]}}"#

        #expect(try rows(result) == [PluginRow(name: "Resets", value: "None")])
    }

    @Test("shows the reset count when the credits have no details")
    func showsResetCountOnly() throws {
        let result =
            #"{"rateLimits":{},"rateLimitResetCredits":{"availableCount":2,"credits":null}}"#

        #expect(try rows(result) == [PluginRow(name: "Resets", value: "2 available")])
    }

    @Test("shows unlimited paid credits")
    func showsUnlimitedCredits() throws {
        let result = #"{"rateLimits":{"credits":{"hasCredits":true,"unlimited":true}}}"#

        #expect(try rows(result) == [PluginRow(name: "Credits", value: "Unlimited")])
    }

    @Test("shows an unknown plan as the server names it")
    func showsUnknownPlan() throws {
        let result = #"{"rateLimits":{"planType":"galaxy_brain"}}"#

        #expect(try rows(result) == [PluginRow(name: "Plan", value: "galaxy_brain")])
    }

    @Test("says there is no usage data when the reply holds none")
    func showsNoUsageData() throws {
        #expect(try rows(#"{"rateLimits":{}}"#) == [PluginRow(name: "No usage data", value: "")])
    }
}

@Suite("Reading the Codex app-server reply")
struct CodexReplyTests {
    @Test("finds the reply after the initialize result and notifications")
    func findsReplyAmongNotifications() throws {
        let lines = [
            #"{"id":0,"result":{"userAgent":"codex"}}"#,
            #"{"method":"remoteControl/status/changed","params":{}}"#,
            #"{"method":"account/updated","params":{}}"#,
            #"{"id":1,"result":{"rateLimits":{"planType":"plus"}}}"#,
        ]

        let matches = lines.map { CodexReply.match(line: Data($0.utf8), id: 1) }

        #expect(matches.prefix(3).allSatisfy { $0 == nil })
        guard case .reply(let result) = matches.last else {
            Issue.record("no reply matched")
            return
        }
        #expect(try CodexReply.parse(result).plan == "plus")
    }

    @Test("reports the server error message")
    func reportsError() {
        let line = #"{"id":0,"error":{"code":-32600,"message":"not logged in"}}"#

        #expect(CodexReply.match(line: Data(line.utf8), id: 0) == .failure("not logged in"))
    }

    @Test("ignores a line that is not JSON")
    func ignoresNonJSON() {
        #expect(CodexReply.match(line: Data("WARN starting".utf8), id: 1) == nil)
    }
}

@Suite("Codex plugin failures")
struct CodexPluginTests {
    private func plugin(_ client: any CodexClient) -> CodexPlugin {
        CodexPlugin(client: client, now: { now }, calendar: utc)
    }

    @Test("shows not found when the codex CLI is missing")
    func showsNotFound() async {
        let client = AppServerClient(locate: { nil }, arguments: [], timeout: 1)

        #expect(await plugin(client).rows() == [PluginRow(name: "codex", value: "not found")])
    }

    @Test("shows the failure of the server call")
    func showsFailure() async {
        let client = FakeCodex(result: .failure(CommandFailure(message: "timed out after 5s")))

        #expect(
            await plugin(client).rows() == [PluginRow(name: "codex", value: "timed out after 5s")])
    }

    @Test("shows an unreadable reply")
    func showsUnreadableReply() async {
        let client = FakeCodex(result: .success(Data(#"{"rateLimits":42}"#.utf8)))

        #expect(
            await plugin(client).rows() == [PluginRow(name: "codex", value: "unreadable reply")])
    }

    @Test("finds codex at the first install path that exists")
    func findsFirstPath() {
        let home = URL(fileURLWithPath: "/Users/me")
        let present: Set = ["/usr/local/bin/codex", "/Users/me/.local/bin/codex"]

        #expect(codexPath(home: home, exists: present.contains) == "/usr/local/bin/codex")
    }
}

@Suite("Talking to codex app-server", .timeLimit(.minutes(1)))
struct AppServerClientTests {
    private static let handshake = """
        read line
        echo '{"method":"remoteControl/status/changed","params":{}}'
        echo '{"id":0,"result":{"userAgent":"fixture"}}'
        read line
        read line
        echo '{"method":"account/updated","params":{}}'
        """

    private func client(_ script: String, timeout: TimeInterval = 5) -> AppServerClient {
        AppServerClient(locate: { "/bin/sh" }, arguments: ["-c", script], timeout: timeout)
    }

    private func failure(_ script: String, timeout: TimeInterval = 5) async -> String? {
        do {
            _ = try await client(script, timeout: timeout).rateLimits()
            return nil
        } catch {
            return "\(error)"
        }
    }

    @Test("returns the rate limits after the handshake")
    func returnsRateLimits() async throws {
        let script =
            Self.handshake + """

                echo '{"id":1,"result":{"rateLimits":{"planType":"pro"}}}'
                read line
                """

        let result = try await client(script).rateLimits()

        #expect(try CodexReply.parse(result).plan == "pro")
    }

    @Test("returns the reply when the server exits right after it")
    func returnsReplyBeforeExit() async throws {
        let script =
            Self.handshake + """

                echo '{"id":1,"result":{"rateLimits":{"planType":"pro"}}}'
                exit 0
                """

        let result = try await client(script).rateLimits()

        #expect(try CodexReply.parse(result).plan == "pro")
    }

    @Test("reports the exit status when the server exits before the reply")
    func reportsEarlyExit() async {
        #expect(await failure("read line; exit 3") == "exited with 3")
    }

    @Test("reports the exit status when the server closes stdout and then exits")
    func reportsExitAfterStdoutClosed() async {
        #expect(await failure("read line; exec >&-; sleep 0.2; exit 4") == "exited with 4")
    }

    @Test("times out when the server does not reply")
    func timesOut() async {
        #expect(await failure("read line; exec sleep 5", timeout: 0.2) == "timed out after 0.2s")
    }

    @Test("times out when a child process keeps stdout open after the server exits")
    func timesOutWithInheritedStdout() async {
        #expect(
            await failure("read line; sleep 1 & exit 0", timeout: 0.2) == "timed out after 0.2s")
    }

    @Test("stops the server when the caller cancels")
    func stopsServerOnCancel() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appending(path: "codex-fixture-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let client = client("echo $$ > '\(pidFile.path)'; read line; exec sleep 30", timeout: 30)

        let call = Task { try await client.rateLimits() }
        let pid = try await waitForPID(pidFile)
        call.cancel()
        let result = await call.result

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(await waitUntilGone(pid))
    }

    private func waitForPID(_ file: URL) async throws -> pid_t {
        for _ in 0..<200 {
            if let text = try? String(contentsOf: file, encoding: .utf8),
                let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return pid
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CommandFailure(message: "fixture wrote no pid")
    }

    private func waitUntilGone(_ pid: pid_t) async -> Bool {
        for _ in 0..<200 {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
