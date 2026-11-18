import Foundation
import Security
import Testing
import os

@testable import TrayStats

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private let realReply = """
    {"five_hour":null,"seven_day":{"utilization":11.0},"limits":[\
    {"kind":"weekly_all","group":"weekly","percent":11,"severity":"normal",\
    "resets_at":"2027-01-17T16:00:00.469588+00:00","scope":null,"is_active":true},\
    {"kind":"weekly_scoped","group":"weekly","percent":4,"severity":"normal",\
    "resets_at":"2027-01-17T16:00:00.469745+00:00",\
    "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}],\
    "weekly_scoped_shares":[{"limit_index":1,"used_percent_of_weekly":2,\
    "allowance_percent_of_weekly":50}],\
    "extra_usage":{"is_enabled":false,"user_disabled":true}}
    """

private func rows(_ reply: String, plan: String? = nil) throws -> [PluginRow] {
    ClaudeRows.rows(
        try ClaudeUsageReply.parse(Data(reply.utf8)), plan: plan, now: now, calendar: utc)
}

private func limits(_ items: String) -> String { #"{"limits":["# + items + "]}" }

@Suite("Showing Claude Code usage")
struct ClaudeRowsTests {
    @Test("shows plan, weekly limits with renewals, the Fable share and extra usage")
    func showsRealReply() throws {
        #expect(
            try rows(realReply, plan: "Max 20x") == [
                PluginRow(name: "Plan", value: "Max 20x"),
                PluginRow(name: "Week", value: "11% used"),
                PluginRow(name: "Renews", value: "Sun 16:00 (in 2d 8h)"),
                PluginRow(name: "Fable week", value: "4% used", dimmed: true),
                PluginRow(name: "Renews", value: "Sun 16:00 (in 2d 8h)", dimmed: true),
                PluginRow(name: "Share of week", value: "2% · allowance 50%", dimmed: true),
                PluginRow(name: "Extra usage", value: "Off"),
            ])
    }

    @Test("warns first when an active limit is used up")
    func warnsWhenLimitReached() throws {
        let reply = limits(#"{"kind":"five_hour","percent":100,"is_active":true}"#)

        #expect(try rows(reply).first == PluginRow(name: "Limit reached", value: "5 hours"))
    }

    @Test("does not warn for a used-up limit that is not active")
    func noWarningForInactiveLimit() throws {
        let reply = limits(#"{"kind":"weekly_all","percent":100,"is_active":false}"#)

        #expect(try rows(reply) == [PluginRow(name: "Week", value: "100% used", dimmed: true)])
    }

    @Test("adds a severity other than normal to the limit")
    func showsSeverity() throws {
        let reply = limits(#"{"kind":"weekly_all","percent":92,"severity":"warning"}"#)

        #expect(try rows(reply) == [PluginRow(name: "Week", value: "92% used · warning")])
    }

    @Test("names a limit of an unknown kind from its kind")
    func namesUnknownKind() throws {
        let reply = limits(#"{"kind":"monthly_all","percent":3}"#)

        #expect(try rows(reply) == [PluginRow(name: "Monthly all", value: "3% used")])
    }

    @Test("keeps a share on its own limit when an earlier limit is unusable")
    func keepsShareOnItsLimit() throws {
        let reply = """
            {"limits":[{"kind":"weekly_all"},\
            {"kind":"weekly_scoped","percent":4,"scope":{"model":{"display_name":"Fable"}}}],\
            "weekly_scoped_shares":[{"limit_index":1,"used_percent_of_weekly":2}]}
            """

        #expect(
            try rows(reply) == [
                PluginRow(name: "Fable week", value: "4% used"),
                PluginRow(name: "Share of week", value: "2%"),
            ])
    }

    @Test("says there is no usage data when no limit has a percentage")
    func showsNoUsageData() throws {
        #expect(try rows("{}", plan: "Pro") == [PluginRow(name: "No usage data", value: "")])
    }

    @Test("reads a renewal time without fractional seconds")
    func readsTimeWithoutFraction() {
        let date = ClaudeUsageReply.date("2027-01-17T13:00:00-03:00")

        #expect(date == Date(timeIntervalSince1970: 1_800_201_600))
    }

    @Test("reads a renewal time with fractional seconds")
    func readsTimeWithFraction() {
        let date = ClaudeUsageReply.date("2027-01-17T16:00:00.500+00:00")

        #expect(date == Date(timeIntervalSince1970: 1_800_201_600.5))
    }

    @Test("names the Max plan with its usage multiplier")
    func namesMaxPlan() {
        #expect(ClaudeRows.plan(subscription: "max", tier: "default_claude_max_20x") == "Max 20x")
        #expect(ClaudeRows.plan(subscription: "pro", tier: "default_claude_ai") == "Pro")
    }
}

@Suite("Reading the Claude Code login")
struct ClaudeLoginTests {
    private static let item = """
        {"mcpOAuth":{},"claudeAiOauth":{"accessToken":"dummy-token","refreshToken":"dummy",\
        "expiresAt":1800003600000,"scopes":["user:inference"],"subscriptionType":"max",\
        "rateLimitTier":"default_claude_max_20x"}}
        """

    @Test("reads the token and its expiry in milliseconds")
    func decodesLogin() throws {
        let credentials = try ClaudeCredentials.decode(Data(Self.item.utf8))

        #expect(
            credentials
                == ClaudeCredentials(
                    accessToken: "dummy-token", expiresAt: now.addingTimeInterval(3600),
                    subscriptionType: "max", rateLimitTier: "default_claude_max_20x"))
    }

    @Test("rejects a login it cannot read")
    func rejectsUnreadableLogin() {
        #expect(throws: ClaudeUsageFailure.unreadableLogin) {
            try ClaudeCredentials.decode(Data("not json".utf8))
        }
    }

    @Test("says not signed in when the Keychain has no Claude Code login")
    func reportsMissingLogin() async {
        let login = KeychainLogin(read: { (errSecItemNotFound, nil) })

        await #expect(throws: ClaudeUsageFailure.notSignedIn) { try await login.credentials() }
    }

    @Test("reports the Keychain status when access is denied")
    func reportsDeniedAccess() async {
        let login = KeychainLogin(read: { (errSecAuthFailed, nil) })

        await #expect(throws: ClaudeUsageFailure.keychain(errSecAuthFailed)) {
            try await login.credentials()
        }
    }

    @Test("does not read the Keychain for a caller cancelled while another read waits")
    func skipsCancelledQueuedRead() async throws {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let release = DispatchSemaphore(value: 0)
        let login = KeychainLogin(read: {
            if reads.withLock({
                $0 += 1
                return $0
            }) == 1 {
                release.wait()
            }
            return (errSecItemNotFound, nil)
        })

        let first = Task { try await login.credentials() }
        while reads.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let second = Task { try await login.credentials() }
        try await Task.sleep(for: .milliseconds(50))
        second.cancel()
        release.signal()
        _ = await first.result
        let result = await second.result

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(reads.withLock { $0 } == 1)
    }
}

@Suite("Reading the usage reply status")
struct ClaudeUsageStatusTests {
    @Test("treats 401 as an expired login")
    func unauthorizedIsExpired() {
        #expect(throws: ClaudeUsageFailure.expired) { try ClaudeUsageFailure.check(status: 401) }
    }

    @Test("reports rate limiting and other statuses")
    func reportsOtherStatuses() {
        #expect(throws: ClaudeUsageFailure.rateLimited) {
            try ClaudeUsageFailure.check(status: 429)
        }
        #expect(throws: ClaudeUsageFailure.http(302)) { try ClaudeUsageFailure.check(status: 302) }
    }

    @Test("says offline when there is no connection")
    func reportsOffline() {
        #expect(ClaudeUsageFailure.from(.notConnectedToInternet) == .offline)
    }
}

private final class Clock: Sendable {
    private let time = OSAllocatedUnfairLock(initialState: now)

    var current: Date { time.withLock { $0 } }

    func advance(_ seconds: TimeInterval) { time.withLock { $0 += seconds } }
}

private final class FakeLogin: ClaudeLogin {
    private let reads = OSAllocatedUnfairLock(initialState: 0)
    let expiresAt: Date

    init(expiresAt: Date = now.addingTimeInterval(3600)) { self.expiresAt = expiresAt }

    var count: Int { reads.withLock { $0 } }

    func credentials() async throws -> ClaudeCredentials {
        reads.withLock { $0 += 1 }

        return ClaudeCredentials(
            accessToken: "dummy-token", expiresAt: expiresAt, subscriptionType: "max",
            rateLimitTier: "default_claude_max_20x")
    }
}

private final class FakeFetcher: UsageFetcher {
    private let calls = OSAllocatedUnfairLock(initialState: 0)
    let result: Result<String, ClaudeUsageFailure>
    let cancelsCaller: Bool

    init(_ result: Result<String, ClaudeUsageFailure>, cancelsCaller: Bool = false) {
        self.result = result
        self.cancelsCaller = cancelsCaller
    }

    var count: Int { calls.withLock { $0 } }

    func usage(token: String) async throws -> Data {
        calls.withLock { $0 += 1 }
        if cancelsCaller { withUnsafeCurrentTask { $0?.cancel() } }

        return Data(try result.get().utf8)
    }
}

@Suite("Claude Code plugin")
struct ClaudeCodePluginTests {
    private func plugin(_ login: FakeLogin, _ fetcher: FakeFetcher, clock: Clock = Clock())
        -> ClaudeCodePlugin
    {
        ClaudeCodePlugin(
            login: login, fetcher: fetcher, now: { clock.current }, calendar: utc)
    }

    @Test("says the login expired without sending a request")
    func expiredLoginSendsNothing() async {
        let fetcher = FakeFetcher(.success(realReply))

        let rows = await plugin(FakeLogin(expiresAt: now), fetcher).rows()

        #expect(rows == [PluginRow(name: "Login expired", value: "Open Claude Code")])
        #expect(fetcher.count == 0)
    }

    @Test("says the login expired when the server rejects the token")
    func rejectedTokenIsExpired() async {
        let rows = await plugin(FakeLogin(), FakeFetcher(.failure(.expired))).rows()

        #expect(rows == [PluginRow(name: "Login expired", value: "Open Claude Code")])
    }

    @Test("shows offline when the request cannot connect")
    func showsOffline() async {
        let rows = await plugin(FakeLogin(), FakeFetcher(.failure(.offline))).rows()

        #expect(rows == [PluginRow(name: "claude", value: "offline")])
    }

    @Test("shows an unreadable reply")
    func showsUnreadableReply() async {
        let rows = await plugin(FakeLogin(), FakeFetcher(.success("[]"))).rows()

        #expect(rows == [PluginRow(name: "claude", value: "unreadable reply")])
    }

    @Test("reuses a result under a minute old without reading the Keychain")
    func reusesRecentResult() async {
        let login = FakeLogin()
        let fetcher = FakeFetcher(.success(realReply))
        let plugin = plugin(login, fetcher)

        let first = await plugin.rows()
        let second = await plugin.rows()

        #expect(second == first)
        #expect(login.count == 1)
        #expect(fetcher.count == 1)
    }

    @Test("fetches again after a minute")
    func refetchesAfterAMinute() async {
        let clock = Clock()
        let fetcher = FakeFetcher(.success(realReply))
        let plugin = plugin(FakeLogin(), fetcher, clock: clock)

        _ = await plugin.rows()
        clock.advance(60)
        _ = await plugin.rows()

        #expect(fetcher.count == 2)
    }

    @Test("stores nothing when the caller is cancelled during the fetch")
    func cancelledFetchStoresNothing() async {
        let cancelling = FakeFetcher(.success(realReply), cancelsCaller: true)
        let login = FakeLogin()
        let first = plugin(login, cancelling)

        let rows = await Task { await first.rows() }.value
        _ = await first.rows()

        #expect(rows == [])
        #expect(cancelling.count == 2)
    }
}
