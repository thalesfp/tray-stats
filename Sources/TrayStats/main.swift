import AppKit

let reader = try SystemReader()
let tartRunners = TartRunnersPlugin(
    config: .standard(home: FileManager.default.homeDirectoryForCurrentUser),
    runner: ProcessRunner(),
    readFile: { try? String(contentsOf: $0, encoding: .utf8) },
    now: { Date() }
)
let codex = CodexPlugin(
    client: AppServerClient(
        locate: {
            codexPath(
                home: FileManager.default.homeDirectoryForCurrentUser,
                exists: FileManager.default.fileExists(atPath:))
        },
        arguments: ["app-server"],
        timeout: 5
    ),
    now: { Date() },
    calendar: .current
)
let claudeCode = ClaudeCodePlugin(
    login: KeychainLogin(), fetcher: URLSessionFetcher(), now: { Date() }, calendar: .current)
let controller = TrayController(
    reader: reader, store: SettingsStore(defaults: .standard),
    plugins: [tartRunners, codex, claudeCode])

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = controller
application.run()
