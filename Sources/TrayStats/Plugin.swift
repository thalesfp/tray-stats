struct PluginRow: Equatable, Sendable {
    var name: String
    var value: String
}

protocol Plugin: Sendable {
    var id: String { get }
    var title: String { get }
    /// How often the rows refresh while the plugin submenu is open.
    var refreshInterval: Duration { get }

    func rows() async -> [PluginRow]
}
