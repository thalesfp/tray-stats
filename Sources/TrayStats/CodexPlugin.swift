import Foundation
import os

/// Reads the Codex account rate limits. Returns the raw JSON `result` of the reply.
protocol CodexClient: Sendable {
    func rateLimits() async throws -> Data
}

struct CodexWindow: Equatable {
    var minutes: Int?
    var usedPercent: Double
    var resetsAt: Date?
}

struct CodexResetCredits: Equatable {
    var count: Int
    var earliestExpiry: Date?
}

enum CodexCredits: Equatable {
    case unlimited
    case balance(String?)
}

struct CodexUsage: Equatable {
    var limitReached: String?
    var plan: String?
    var windows: [CodexWindow]
    var resetCredits: CodexResetCredits?
    var credits: CodexCredits?
}

enum CodexReply {
    enum Match: Equatable {
        case reply(Data)
        case failure(String)
    }

    /// A JSON-RPC reply to the request `id`: it has that id, a result or an error, and no method.
    /// Notifications, server requests, other ids and lines that are not JSON give nil.
    static func match(line: Data, id: Int) -> Match? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            object["method"] == nil,
            (object["id"] as? NSNumber)?.intValue == id
        else { return nil }

        if let error = object["error"] {
            let message = (error as? [String: Any])?["message"] as? String

            return .failure(message ?? "unknown error")
        }

        guard let result = object["result"],
            let data = try? JSONSerialization.data(
                withJSONObject: result, options: .fragmentsAllowed)
        else { return nil }

        return .reply(data)
    }

    /// Decodes the `account/rateLimits/read` result. Uses the top-level `rateLimits` view only.
    static func parse(_ data: Data) throws -> CodexUsage {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let limits = response.rateLimits

        let windows = [limits?.primary, limits?.secondary].compactMap { window -> CodexWindow? in
            guard let window, let used = window.usedPercent else { return nil }

            return CodexWindow(
                minutes: window.windowDurationMins, usedPercent: used,
                resetsAt: window.resetsAt.map(date))
        }

        let resetCredits = response.rateLimitResetCredits.map { summary in
            CodexResetCredits(
                count: summary.availableCount,
                earliestExpiry: summary.credits?
                    .filter { $0.status == "available" }
                    .compactMap { $0.expiresAt.map(date) }
                    .min())
        }

        let credits = limits?.credits.map { credits -> CodexCredits in
            credits.unlimited == true ? .unlimited : .balance(credits.balance)
        }

        return CodexUsage(
            limitReached: limits?.rateLimitReachedType, plan: limits?.planType, windows: windows,
            resetCredits: resetCredits, credits: credits)
    }

    private static func date(_ seconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    private struct Response: Decodable {
        var rateLimits: Snapshot?
        var rateLimitResetCredits: ResetSummary?
    }

    private struct Snapshot: Decodable {
        var primary: Window?
        var secondary: Window?
        var credits: Credits?
        var planType: String?
        var rateLimitReachedType: String?
    }

    private struct Window: Decodable {
        var usedPercent: Double?
        var windowDurationMins: Int?
        var resetsAt: Int64?
    }

    private struct Credits: Decodable {
        var unlimited: Bool?
        var balance: String?
    }

    private struct ResetSummary: Decodable {
        var availableCount: Int
        var credits: [ResetCredit]?
    }

    private struct ResetCredit: Decodable {
        var status: String?
        var expiresAt: Int64?
    }
}

enum CodexRows {
    private static let errorLimit = 40
    private static let plans = [
        "free": "Free", "go": "Go", "plus": "Plus", "pro": "Pro", "prolite": "Pro Lite",
        "promax": "Pro Max", "team": "Team", "business": "Business", "enterprise": "Enterprise",
        "edu": "Edu",
    ]

    static func rows(_ usage: CodexUsage, now: Date, calendar: Calendar) -> [PluginRow] {
        var rows: [PluginRow] = []

        if let reached = usage.limitReached {
            rows.append(PluginRow(name: "Limit reached", value: sentence(reached)))
        }

        if let plan = usage.plan {
            rows.append(PluginRow(name: "Plan", value: plans[plan] ?? plan))
        }

        for window in usage.windows {
            rows.append(
                PluginRow(
                    name: windowLabel(window.minutes),
                    value: "\(Int(window.usedPercent.rounded()))% used"))

            if let resetsAt = window.resetsAt {
                rows.append(
                    PluginRow(
                        name: "Renews",
                        value: Format.renewal(resetsAt, now: now, calendar: calendar)))
            }
        }

        if let resets = usage.resetCredits {
            rows.append(PluginRow(name: "Resets", value: resetLabel(resets, calendar: calendar)))
        }

        switch usage.credits {
        case .unlimited:
            rows.append(PluginRow(name: "Credits", value: "Unlimited"))
        case .balance(let balance):
            rows.append(PluginRow(name: "Credits", value: balance ?? "–"))
        case nil:
            break
        }

        return rows.isEmpty ? [PluginRow(name: "No usage data", value: "")] : rows
    }

    static func failure(_ message: String) -> [PluginRow] {
        [PluginRow(name: "codex", value: Format.clipped(message, limit: errorLimit))]
    }

    private static func windowLabel(_ minutes: Int?) -> String {
        guard let minutes else { return "Limit" }

        switch minutes {
        case 10080: return "Week"
        case let minutes where minutes % 1440 == 0: return "\(minutes / 1440) days"
        case let minutes where minutes % 60 == 0: return "\(minutes / 60) hours"
        default: return "\(minutes) minutes"
        }
    }

    private static func resetLabel(_ resets: CodexResetCredits, calendar: Calendar) -> String {
        guard resets.count > 0 else { return "None" }

        let available = "\(resets.count) available"
        guard let expiry = resets.earliestExpiry else { return available }

        return "\(available) · expires \(Format.date(expiry, "MMM d", calendar: calendar))"
    }

    private static func sentence(_ code: String) -> String {
        let words = code.replacingOccurrences(of: "_", with: " ")

        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

/// The first Codex CLI path that exists, in the order Homebrew (Apple Silicon, Intel), then the
/// standalone installer uses.
func codexPath(home: URL, exists: (String) -> Bool) -> String? {
    [
        "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
        home.appending(path: ".local/bin/codex").path,
    ]
    .first(where: exists)
}

struct CodexPlugin: Plugin {
    let id = "codex"
    let title = "Codex"
    let refreshInterval: Duration? = .seconds(60)

    let client: any CodexClient
    let now: @Sendable () -> Date
    let calendar: Calendar

    func rows() async -> [PluginRow] {
        let data: Data
        do {
            data = try await client.rateLimits()
        } catch {
            return CodexRows.failure("\(error)")
        }

        guard let usage = try? CodexReply.parse(data) else {
            return CodexRows.failure("unreadable reply")
        }

        return CodexRows.rows(usage, now: now(), calendar: calendar)
    }
}

/// Asks `codex app-server` for the rate limits over JSON-RPC on stdio, one JSON object per line.
/// It sends only initialize, initialized and account/rateLimits/read.
struct AppServerClient: CodexClient {
    let locate: @Sendable () -> String?
    let arguments: [String]
    let timeout: TimeInterval

    func rateLimits() async throws -> Data {
        guard let path = locate() else { throw CommandFailure(message: "not found") }

        let session = AppServerSession(path: path, arguments: arguments, timeout: timeout)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { session.start($0) }
        } onCancel: {
            session.cancel()
        }
    }
}

private enum AppServerMethod {
    static let initialize = "initialize"
    static let initialized = "initialized"
    static let readRateLimits = "account/rateLimits/read"
}

/// One app-server call. Every end path (reply, failure, exit, timeout, cancel) claims `finished`
/// under the lock once; the first one resumes the caller and stops the server.
private final class AppServerSession: Sendable {
    private enum Phase {
        case idle
        case cancelled
        case launched
        case finished
    }

    private struct State {
        var phase = Phase.idle
        var continuation: CheckedContinuation<Data, any Error>?
        var buffer = Data()
        var expecting = 0
        var stdoutClosed = false
        var exitStatus: Int32?
    }

    private static let initializeID = 0
    private static let readID = 1

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let timeout: TimeInterval
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(path: String, arguments: [String], timeout: TimeInterval) {
        self.timeout = timeout
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    func start(_ continuation: CheckedContinuation<Data, any Error>) {
        let launch = state.withLock { state in
            guard state.phase == .idle else { return false }

            state.phase = .launched
            state.continuation = continuation
            return true
        }
        guard launch else {
            continuation.resume(throwing: CancellationError())
            return
        }

        // Without this, a write to a server that has exited raises SIGPIPE and ends Tray Stats.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            finish(.failure(CommandFailure(message: "could not set up input: errno \(errno)")))
            return
        }

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        process.terminationHandler = { [weak self] process in
            self?.exited(process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            finish(.failure(CommandFailure(message: error.localizedDescription)))
            return
        }

        // A cancel that came during run() found no running process to stop.
        if state.withLock({ $0.phase == .finished }) {
            output.fileHandleForReading.readabilityHandler = nil
            stopProcess(process)
            return
        }

        send(
            id: Self.initializeID, method: AppServerMethod.initialize,
            params: ["clientInfo": ["name": "tray-stats", "version": "1"]])

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }

            let seconds = String(format: "%g", self.timeout)
            finish(.failure(CommandFailure(message: "timed out after \(seconds)s")))
        }
    }

    func cancel() {
        let notLaunched = state.withLock { state in
            guard state.phase == .idle else { return false }

            state.phase = .cancelled
            return true
        }
        guard !notLaunched else { return }

        finish(.failure(CancellationError()))
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else {
            output.fileHandleForReading.readabilityHandler = nil
            let (rest, status) = state.withLock { state in
                state.stdoutClosed = true
                defer { state.buffer = Data() }
                return (state.buffer, state.exitStatus)
            }
            if !rest.isEmpty { handle(rest) }
            if let status { finish(.failure(exitFailure(status))) }
            return
        }

        let lines = state.withLock { state in
            state.buffer.append(data)

            var lines: [Data] = []
            while let end = state.buffer.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(Data(state.buffer[state.buffer.startIndex..<end]))
                state.buffer.removeSubrange(state.buffer.startIndex...end)
            }
            return lines
        }

        for line in lines { handle(line) }
    }

    private func handle(_ line: Data) {
        let expecting = state.withLock { $0.expecting }

        switch CodexReply.match(line: line, id: expecting) {
        case .reply(let result) where expecting == Self.readID:
            finish(.success(result))
        case .reply:
            state.withLock { $0.expecting = Self.readID }
            send(method: AppServerMethod.initialized)
            send(id: Self.readID, method: AppServerMethod.readRateLimits)
        case .failure(let message):
            finish(.failure(CommandFailure(message: message)))
        case nil:
            break
        }
    }

    private func exited(_ status: Int32) {
        let closed = state.withLock { state in
            state.exitStatus = status
            return state.stdoutClosed
        }
        if closed { finish(.failure(exitFailure(status))) }
    }

    private func exitFailure(_ status: Int32) -> CommandFailure {
        CommandFailure(message: "exited with \(status)")
    }

    /// Writes one JSON-RPC message. Writes and the close in `finish` share the lock, so no
    /// write goes to a closed handle.
    private func send(id: Int? = nil, method: String, params: [String: Any]? = nil) {
        var message: [String: Any] = ["method": method]
        message["id"] = id
        message["params"] = params

        let line: Data
        do {
            line = try JSONSerialization.data(withJSONObject: message) + Data("\n".utf8)
        } catch {
            finish(.failure(error))
            return
        }

        let failure = state.withLock { state -> (any Error)? in
            guard state.phase == .launched else { return nil }

            do {
                try input.fileHandleForWriting.write(contentsOf: line)
                return nil
            } catch {
                return error
            }
        }
        if let failure {
            finish(.failure(CommandFailure(message: "could not write: \(failure)")))
        }
    }

    private func finish(_ result: Result<Data, any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<Data, any Error>? in
            guard state.phase == .launched else { return nil }

            state.phase = .finished
            // Closing a pipe end fails only for a descriptor that is already closed.
            try? input.fileHandleForWriting.close()
            defer { state.continuation = nil }
            return state.continuation
        }
        guard let continuation else { return }

        output.fileHandleForReading.readabilityHandler = nil
        stopProcess(process)
        continuation.resume(with: result)
    }
}
