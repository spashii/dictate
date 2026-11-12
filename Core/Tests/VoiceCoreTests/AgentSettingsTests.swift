import Foundation
import Testing
@testable import VoiceCore

@Suite struct AgentSettingsTests {
    private func defaults() -> UserDefaults { defaults(named: "dictate-tests-\(UUID().uuidString)") }

    private func defaults(named name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func support(folders: [String] = []) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "dictate-support-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for folder in folders {
            try FileManager.default.createDirectory(at: url.appending(path: folder), withIntermediateDirectories: true)
        }
        return url
    }

    @Test func aNewInstallStartsWithTheWritingToolsOffAndKeepsThatChoice() {
        let store = defaults()
        #expect(AgentSettings.disabledTools(in: store, existingInstall: false) == MCPServer.offByDefault)
        // Stored, so a later launch (when the data folder exists) doesn't read it as an old install.
        #expect(store.stringArray(forKey: AgentSettings.disabledToolsKey) != nil)
        #expect(AgentSettings.disabledTools(in: store, existingInstall: true) == MCPServer.offByDefault)
    }

    @Test func anExistingInstallKeepsEveryToolOn() {
        let store = defaults()
        #expect(AgentSettings.disabledTools(in: store, existingInstall: true).isEmpty)
        #expect(store.stringArray(forKey: AgentSettings.disabledToolsKey) == [])
        #expect(AgentSettings.disabledTools(in: store, existingInstall: false).isEmpty)
    }

    @Test func aStoredChoiceWins() {
        let store = defaults()
        store.set(["list_calls"], forKey: AgentSettings.disabledToolsKey)
        #expect(AgentSettings.disabledTools(in: store, existingInstall: false) == ["list_calls"])
    }

    @Test func eitherDataFolderMeansAnExistingInstall() throws {
        let name = "dictate-tests-\(UUID().uuidString)"
        let store = defaults(named: name)
        #expect(try AgentSettings.isExistingInstall(support: support(folders: ["Voice"]), defaults: store, domain: name))
        #expect(try AgentSettings.isExistingInstall(support: support(folders: ["Dictate"]), defaults: store, domain: name))
        #expect(try !AgentSettings.isExistingInstall(support: support(), defaults: store, domain: name))
    }

    @Test func anyEarlierPreferenceMeansAnExistingInstall() throws {
        let name = "dictate-tests-\(UUID().uuidString)"
        let store = defaults(named: name)
        store.set(true, forKey: "agentAccess")
        #expect(try AgentSettings.isExistingInstall(support: support(), defaults: store, domain: name))
    }

    @Test func theCLIReadsTheAppsEndpointAndFallsBackToTheDefaults() {
        let store = defaults()
        #expect(AgentSettings.endpoint(in: store) == (MCPEndpoint.defaultHost, MCPServer.defaultPort))
        store.set("localhost", forKey: AgentSettings.hostKey)
        store.set(8123, forKey: AgentSettings.portKey)
        #expect(AgentSettings.endpoint(in: store) == ("127.0.0.1", 8123))
        store.set("nonsense", forKey: AgentSettings.hostKey)
        #expect(AgentSettings.endpoint(in: store).host == MCPEndpoint.defaultHost)
    }

    @Test func theCLIAppliesTheAppsToolSwitchesWithoutWritingThem() {
        let store = defaults()
        #expect(AgentSettings.disabledToolsForReading(in: store) == MCPServer.offByDefault)
        #expect(store.stringArray(forKey: AgentSettings.disabledToolsKey) == nil)
        store.set(["get_call"], forKey: AgentSettings.disabledToolsKey)
        #expect(AgentSettings.disabledToolsForReading(in: store) == ["get_call"])
    }
}
