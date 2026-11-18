import Foundation
import Security
import os

/// A failure shown as a fixed message: no thrown error, header or reply body ever reaches a row.
enum ClaudeUsageFailure: Error, Equatable, CustomStringConvertible {
    case notSignedIn
    case keychain(OSStatus)
    case unreadableLogin
    case expired
    case offline
    case timedOut
    case rateLimited
    case http(Int)
    case network
    case unreadableReply
    case unexpected

    var description: String {
        switch self {
        case .notSignedIn: "not signed in"
        case .keychain(let status): "Keychain error \(status)"
        case .unreadableLogin: "unreadable login"
        case .expired: "login expired"
        case .offline: "offline"
        case .timedOut: "timed out"
        case .rateLimited: "rate limited"
        case .http(let status): "HTTP \(status)"
        case .network: "network error"
        case .unreadableReply: "unreadable reply"
        case .unexpected: "unexpected error"
        }
    }

    static func from(_ code: URLError.Code) -> ClaudeUsageFailure {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: .offline
        case .timedOut: .timedOut
        default: .network
        }
    }

    /// Maps the HTTP status of the usage reply. Claude Code refreshes an expired token, so a
    /// 401 means its login is out of date.
    static func check(status: Int) throws(ClaudeUsageFailure) {
        switch status {
        case 200: return
        case 401: throw .expired
        case 429: throw .rateLimited
        default: throw .http(status)
        }
    }
}

struct ClaudeCredentials: Equatable, Sendable, CustomStringConvertible {
    var accessToken: String
    var expiresAt: Date
    var subscriptionType: String?
    var rateLimitTier: String?

    var description: String { "ClaudeCredentials(expiresAt: \(expiresAt))" }

    /// Decodes the Claude Code Keychain item. `expiresAt` is in milliseconds since 1970.
    static func decode(_ data: Data) throws(ClaudeUsageFailure) -> ClaudeCredentials {
        guard let item = try? JSONDecoder().decode(Item.self, from: data),
            let login = item.claudeAiOauth
        else { throw .unreadableLogin }

        return ClaudeCredentials(
            accessToken: login.accessToken,
            expiresAt: Date(timeIntervalSince1970: login.expiresAt / 1000),
            subscriptionType: login.subscriptionType,
            rateLimitTier: login.rateLimitTier)
    }

    private struct Item: Decodable {
        var claudeAiOauth: Login?
    }

    private struct Login: Decodable {
        var accessToken: String
        var expiresAt: Double
        var subscriptionType: String?
        var rateLimitTier: String?
    }
}

protocol ClaudeLogin: Sendable {
    func credentials() async throws -> ClaudeCredentials
}

/// Reads the login Claude Code keeps in the Keychain. Never writes it and never refreshes it.
actor KeychainLogin: ClaudeLogin {
    typealias Read = @Sendable () -> (status: OSStatus, data: Data?)

    private let read: Read

    init(read: @escaping Read = KeychainLogin.readItem) {
        self.read = read
    }

    /// The read has no suspension point, so the actor runs one read (and one Keychain prompt)
    /// at a time. A caller cancelled while it waits never reaches the Keychain.
    func credentials() async throws -> ClaudeCredentials {
        try Task.checkCancellation()

        let (status, data) = read()
        switch status {
        case errSecSuccess:
            guard let data else { throw ClaudeUsageFailure.unreadableLogin }

            return try ClaudeCredentials.decode(data)
        case errSecItemNotFound:
            throw ClaudeUsageFailure.notSignedIn
        default:
            throw ClaudeUsageFailure.keychain(status)
        }
    }

    static func readItem() -> (status: OSStatus, data: Data?) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "Claude Code-credentials",
            kSecAttrAccount: NSUserName(),
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        return (status, result as? Data)
    }
}

protocol UsageFetcher: Sendable {
    func usage(token: String) async throws -> Data
}

/// Fetches the usage reply that Claude Code's /usage shows. The endpoint is not documented.
final class URLSessionFetcher: NSObject, UsageFetcher, URLSessionTaskDelegate, Sendable {
    private static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let timeout: TimeInterval = 10

    private let session: URLSession

    override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        session = URLSession(configuration: configuration)
        super.init()
    }

    func usage(token: String) async throws -> Data {
        var request = URLRequest(url: Self.url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: self)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw ClaudeUsageFailure.from(error.code)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ClaudeUsageFailure.network
        }

        guard let http = response as? HTTPURLResponse else { throw ClaudeUsageFailure.network }
        try ClaudeUsageFailure.check(status: http.statusCode)

        return data
    }

    /// A redirect would send the bearer token to another URL, so the 3xx reply is used as is.
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

struct ClaudeLimit: Equatable, Sendable {
    /// Position in the reply's `limits` list; `weekly_scoped_shares` points at it.
    var index: Int
    var kind: String?
    var percent: Double
    var severity: String?
    var resetsAt: Date?
    var scope: String?
    var active: Bool
}

struct ClaudeShare: Equatable, Sendable {
    var limitIndex: Int
    var used: Double
    var allowance: Double?
}

struct ClaudeUsage: Equatable, Sendable {
    var limits: [ClaudeLimit]
    var shares: [ClaudeShare]
    var extraUsageEnabled: Bool?
}

enum ClaudeUsageReply {
    static func parse(_ data: Data) throws(ClaudeUsageFailure) -> ClaudeUsage {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let reply = try? decoder.decode(Reply.self, from: data) else {
            throw .unreadableReply
        }

        let limits = (reply.limits ?? []).enumerated().compactMap {
            index, entry -> ClaudeLimit? in
            guard let limit = entry.value, let percent = limit.percent else { return nil }

            return ClaudeLimit(
                index: index, kind: limit.kind, percent: percent, severity: limit.severity,
                resetsAt: limit.resetsAt.flatMap(date), scope: limit.scope?.model?.displayName,
                active: limit.isActive ?? true)
        }

        let shares = (reply.weeklyScopedShares ?? []).compactMap { entry -> ClaudeShare? in
            guard let share = entry.value, let index = share.limitIndex,
                let used = share.usedPercentOfWeekly
            else { return nil }

            return ClaudeShare(
                limitIndex: index, used: used, allowance: share.allowancePercentOfWeekly)
        }

        return ClaudeUsage(
            limits: limits, shares: shares, extraUsageEnabled: reply.extraUsage?.isEnabled)
    }

    /// Before Foundation 6.2 (macOS 14), the fractional style needs a fraction, so both styles
    /// are tried.
    static func date(_ text: String) -> Date? {
        (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: Date.ISO8601FormatStyle()))
    }

    /// A list entry that does not decode is dropped without failing the whole reply.
    private struct Lenient<Value: Decodable>: Decodable {
        var value: Value?

        init(from decoder: any Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    private struct Reply: Decodable {
        var limits: [Lenient<Limit>]?
        var weeklyScopedShares: [Lenient<Share>]?
        var extraUsage: ExtraUsage?
    }

    private struct Limit: Decodable {
        var kind: String?
        var percent: Double?
        var severity: String?
        var resetsAt: String?
        var scope: Scope?
        var isActive: Bool?
    }

    private struct Scope: Decodable {
        var model: Model?
    }

    private struct Model: Decodable {
        var displayName: String?
    }

    private struct Share: Decodable {
        var limitIndex: Int?
        var usedPercentOfWeekly: Double?
        var allowancePercentOfWeekly: Double?
    }

    private struct ExtraUsage: Decodable {
        var isEnabled: Bool?
    }
}

enum ClaudeRows {
    static func rows(_ usage: ClaudeUsage, plan: String?, now: Date, calendar: Calendar)
        -> [PluginRow]
    {
        guard !usage.limits.isEmpty else { return [PluginRow(name: "No usage data", value: "")] }

        var rows: [PluginRow] = []

        if let reached = usage.limits.first(where: { $0.active && $0.percent >= 100 }) {
            rows.append(PluginRow(name: "Limit reached", value: label(reached)))
        }

        if let plan {
            rows.append(PluginRow(name: "Plan", value: plan))
        }

        for limit in usage.limits {
            let dimmed = !limit.active
            rows.append(PluginRow(name: label(limit), value: usedLabel(limit), dimmed: dimmed))

            if let resetsAt = limit.resetsAt {
                rows.append(
                    PluginRow(
                        name: "Renews",
                        value: Format.renewal(resetsAt, now: now, calendar: calendar),
                        dimmed: dimmed))
            }

            for share in usage.shares where share.limitIndex == limit.index {
                rows.append(
                    PluginRow(name: "Share of week", value: shareLabel(share), dimmed: dimmed))
            }
        }

        if let enabled = usage.extraUsageEnabled {
            rows.append(PluginRow(name: "Extra usage", value: enabled ? "On" : "Off"))
        }

        return rows
    }

    static func failure(_ failure: ClaudeUsageFailure) -> [PluginRow] {
        guard failure != .expired else {
            return [PluginRow(name: "Login expired", value: "Open Claude Code")]
        }

        return [PluginRow(name: "claude", value: failure.description)]
    }

    /// "Max 20x" from subscription type "max" and tier "default_claude_max_20x".
    static func plan(subscription: String?, tier: String?) -> String? {
        guard let subscription else { return nil }

        let name = subscription.prefix(1).uppercased() + subscription.dropFirst()
        guard subscription == "max", let tier,
            let multiplier = tier.split(separator: "_").last, multiplier.hasSuffix("x")
        else { return name }

        return "\(name) \(multiplier)"
    }

    private static func label(_ limit: ClaudeLimit) -> String {
        switch limit.kind {
        case "weekly_all": return "Week"
        case "weekly_scoped": return "\(limit.scope ?? "Scoped") week"
        case let kind? where kind.hasPrefix("five_hour"): return "5 hours"
        case let kind?: return sentence(kind)
        case nil: return "Limit"
        }
    }

    private static func usedLabel(_ limit: ClaudeLimit) -> String {
        let used = "\(Int(limit.percent.rounded()))% used"
        guard let severity = limit.severity, severity != "normal" else { return used }

        return "\(used) · \(severity.replacingOccurrences(of: "_", with: " "))"
    }

    private static func shareLabel(_ share: ClaudeShare) -> String {
        let used = "\(Int(share.used.rounded()))%"
        guard let allowance = share.allowance else { return used }

        return "\(used) · allowance \(Int(allowance.rounded()))%"
    }

    private static func sentence(_ code: String) -> String {
        let words = code.replacingOccurrences(of: "_", with: " ")

        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

struct ClaudeCodePlugin: Plugin {
    private static let reuse: TimeInterval = 60

    private struct Fetched: Sendable {
        var usage: ClaudeUsage
        var plan: String?
        var fetchedAt: Date
        var expiresAt: Date
    }

    let id = "claudeCode"
    let title = "Claude Code"
    let refreshInterval: Duration? = nil

    let login: any ClaudeLogin
    let fetcher: any UsageFetcher
    let now: @Sendable () -> Date
    let calendar: Calendar

    private let last = OSAllocatedUnfairLock<Fetched?>(initialState: nil)

    init(
        login: any ClaudeLogin, fetcher: any UsageFetcher, now: @escaping @Sendable () -> Date,
        calendar: Calendar
    ) {
        self.login = login
        self.fetcher = fetcher
        self.now = now
        self.calendar = calendar
    }

    /// Reuses a result under 60 s old without a Keychain read. A cancelled call returns no rows
    /// and stores nothing.
    func rows() async -> [PluginRow] {
        let start = now()
        if let fetched = last.withLock({ $0 }),
            start.timeIntervalSince(fetched.fetchedAt) < Self.reuse, fetched.expiresAt > start
        {
            return rows(fetched)
        }

        do {
            let credentials = try await login.credentials()
            try Task.checkCancellation()
            guard credentials.expiresAt > now() else { throw ClaudeUsageFailure.expired }

            let data = try await fetcher.usage(token: credentials.accessToken)
            let fetched = Fetched(
                usage: try ClaudeUsageReply.parse(data),
                plan: ClaudeRows.plan(
                    subscription: credentials.subscriptionType, tier: credentials.rateLimitTier),
                fetchedAt: now(), expiresAt: credentials.expiresAt)

            let stored = last.withLock { last in
                guard !Task.isCancelled else { return false }

                last = fetched
                return true
            }
            guard stored else { return [] }

            return rows(fetched)
        } catch is CancellationError {
            return []
        } catch let failure as ClaudeUsageFailure {
            return ClaudeRows.failure(failure)
        } catch {
            return ClaudeRows.failure(.unexpected)
        }
    }

    private func rows(_ fetched: Fetched) -> [PluginRow] {
        ClaudeRows.rows(fetched.usage, plan: fetched.plan, now: now(), calendar: calendar)
    }
}
