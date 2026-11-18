struct PluginRow: Equatable, Sendable {
    var name: String
    var value: String
    var dimmed = false
}

protocol Plugin: Sendable {
    var id: String { get }
    var title: String { get }
    /// How often the rows refresh while the plugin submenu is open; nil loads once per open.
    var refreshInterval: Duration? { get }

    func rows() async -> [PluginRow]
}
