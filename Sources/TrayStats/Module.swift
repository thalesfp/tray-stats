struct ModuleRow: Equatable, Sendable {
    var name: String
    var value: String
}

protocol Module: Sendable {
    var id: String { get }
    var title: String { get }

    func rows() async -> [ModuleRow]
}
