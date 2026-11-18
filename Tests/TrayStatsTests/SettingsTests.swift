import Foundation
import Testing

@testable import TrayStats

private func store() -> SettingsStore {
    let suite = "traystats.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)

    return SettingsStore(defaults: defaults)
}

@Suite("Plugin settings")
struct SettingsTests {
    @Test("keeps a hidden plugin hidden after the setting moves to its new name")
    func keepsHiddenPlugin() {
        let store = store()
        store.defaults.set(false, forKey: "show.module.tartRunners")

        store.migratePluginKeys(ids: ["tartRunners"])

        #expect(!store.isShown(plugin: "tartRunners"))
        #expect(store.defaults.object(forKey: "show.module.tartRunners") == nil)
    }

    @Test("keeps the new setting when both the old and the new one exist")
    func newSettingWins() {
        let store = store()
        store.defaults.set(false, forKey: "show.module.tartRunners")
        store.save(plugin: "tartRunners", shown: true)

        store.migratePluginKeys(ids: ["tartRunners"])

        #expect(store.isShown(plugin: "tartRunners"))
    }

    @Test("shows a plugin that has no setting")
    func showsByDefault() {
        #expect(store().isShown(plugin: "codex"))
    }
}
