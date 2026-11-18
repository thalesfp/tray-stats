import AppKit

let reader = try SystemReader()
let tartRunners = TartRunnerModule(
    config: .standard(home: FileManager.default.homeDirectoryForCurrentUser),
    runner: ProcessRunner(),
    readFile: { try? String(contentsOf: $0, encoding: .utf8) },
    now: { Date() }
)
let controller = TrayController(
    reader: reader, store: SettingsStore(defaults: .standard), modules: [tartRunners])

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = controller
application.run()
