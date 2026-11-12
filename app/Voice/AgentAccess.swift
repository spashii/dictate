import AppKit
import Observation
import SwiftUI
import VoiceCore

/// The MCP server agents read dictations and call transcripts through, hosted while Dictate
/// runs. dictate-cli mcp serves the same thing when Dictate isn't running; only one of them can
/// hold the port.
@MainActor @Observable
final class AgentAccess {
    enum Status: Equatable {
        case off
        case starting
        case on
        case failed(String)
    }

    /// On by default: an agent also needs the token, and the server listens on this Mac only
    /// unless the address says otherwise.
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "agentAccess")
            apply()
        }
    }
    private(set) var status: Status = .off
    private(set) var host: String
    private(set) var port: UInt16
    /// The tools an agent can't see or call. Changes reach a running server at once.
    private(set) var disabledTools: Set<String>
    /// The current token, read when Settings needs it.
    private(set) var token: String?

    /// What start_recording and stop_recording go through; set before launch.
    @ObservationIgnored var recording: (any RecordingControl)?
    /// Where agents' key-term changes go: Preferences, so Settings shows them as they land.
    @ObservationIgnored var keyTerms: (any KeyTermsSettings)?
    @ObservationIgnored private var server: MCPServer?
    /// Counts starts and stops, so a start that finishes after the switch moved again is dropped.
    @ObservationIgnored private var generation = 0

    init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: "agentAccess") as? Bool ?? true
        host = defaults.string(forKey: "agentHost").flatMap(MCPEndpoint.address(host:)) ?? MCPEndpoint.defaultHost
        port = (defaults.object(forKey: "agentPort") as? Int).flatMap { UInt16(exactly: $0) } ?? MCPServer.defaultPort
        // Nobody who has set a tool keeps the defaults; an explicit choice, even all on, is kept.
        disabledTools = defaults.stringArray(forKey: "agentDisabledTools").map(Set.init) ?? MCPServer.offByDefault
        token = try? MCPToken.load()
    }

    func launch() {
        apply()
    }

    var localAddress: String { MCPSetup(host: host, port: port, token: "").url }

    /// The token with all but its last four characters hidden.
    var maskedToken: String {
        guard let token else { return "" }
        return String(repeating: "\u{2022}", count: 12) + token.suffix(4)
    }

    /// What the Connect box shows: the token is not on screen.
    var displayedSetup: MCPSetup { MCPSetup(host: host, port: port, token: "<token>") }

    func copyToken() {
        guard let token = token ?? (try? MCPToken.load()) else { return }
        copy(token)
    }

    /// The JSON and the command, with this Mac's address and token filled in.
    func copySetup() {
        guard let token = token ?? (try? MCPToken.load()) else { return }
        copy(MCPSetup(host: host, port: port, token: token).copied)
    }

    /// A new token. Agents holding the old one are refused until they get this one, and the
    /// server restarts so it checks against it.
    func regenerateToken() {
        token = try? MCPToken.regenerate()
        apply()
    }

    /// Moves the server to the address. Nothing changes when either part isn't valid; the
    /// caller has already said so.
    func setAddress(host: String, port: UInt16) {
        guard let host = MCPEndpoint.address(host: host), host != self.host || port != self.port else { return }
        self.host = host
        self.port = port
        UserDefaults.standard.set(host, forKey: "agentHost")
        UserDefaults.standard.set(Int(port), forKey: "agentPort")
        apply()
    }

    func setTool(_ name: String, on: Bool) {
        if on { disabledTools.remove(name) } else { disabledTools.insert(name) }
        toolsChanged()
    }

    func setAllTools(on: Bool) {
        disabledTools = on ? [] : Set(MCPServer.toolCatalog.map(\.name))
        toolsChanged()
    }

    private func toolsChanged() {
        UserDefaults.standard.set(disabledTools.sorted(), forKey: "agentDisabledTools")
        server?.disabledTools = disabledTools
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func apply() {
        generation += 1
        let current = generation
        server?.stop()
        server = nil
        guard enabled else {
            status = .off
            return
        }
        status = .starting
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let recording = recording
        let keyTerms = keyTerms
        let host = host, port = port, disabled = disabledTools
        Task {
            do {
                // Opening the store can migrate the database; that stays off the main thread.
                let server = try await Task.detached {
                    MCPServer(store: try CallStore(url: Paths.database), token: try MCPToken.load(), port: port,
                              recording: recording, keyTerms: keyTerms, version: version, host: host,
                              disabledTools: disabled)
                }.value
                try await server.start()
                guard current == generation else { return server.stop() }
                // A switch flipped while the server was starting.
                server.disabledTools = disabledTools
                self.server = server
                status = .on
            } catch {
                guard current == generation else { return }
                status = .failed("\(error)")
            }
        }
    }
}
