import Foundation
import Testing
@testable import VoiceCore

@Suite struct MCPToolSwitchTests {
    private func router(disabled: Set<String> = []) throws -> MCPRouter {
        MCPRouter(store: try CallStore(url: temporaryCallDatabase()), recording: nil, recordingUnavailable: "",
                  version: "0", switches: ToolSwitches(disabled: disabled))
    }

    private func send(_ router: MCPRouter, _ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        let (_, answer) = await router.handle(body)
        let data = try #require(answer)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func listed(_ router: MCPRouter) async throws -> [String] {
        let reply = try await send(router, "tools/list")
        let result = try #require(reply["result"] as? [String: Any])
        return (result["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    @Test func everyToolIsListedByDefault() async throws {
        let names = try await listed(try router())
        #expect(names == MCPServer.toolCatalog.map(\.name))
        #expect(names.contains("list_calls"))
    }

    @Test func aDisabledToolIsAbsentFromTheList() async throws {
        let names = try await listed(try router(disabled: ["list_calls", "start_recording"]))
        #expect(!names.contains("list_calls"))
        #expect(!names.contains("start_recording"))
        #expect(names.contains("get_call"))
    }

    @Test func aDisabledToolRefusesCalls() async throws {
        let router = try router(disabled: ["list_calls"])
        let reply = try await send(router, "tools/call", ["name": "list_calls", "arguments": [String: Any]()])
        let error = try #require(reply["error"] as? [String: Any])
        #expect((error["message"] as? String)?.contains("turned off") == true)
        #expect(reply["result"] == nil)
        let other = try await send(router, "tools/call", ["name": "list_dictations", "arguments": [String: Any]()])
        #expect(other["error"] == nil)
    }

    @Test func switchingAToolBackOnTakesEffectAtOnce() async throws {
        let router = try router(disabled: ["list_calls"])
        router.switches.disabled = []
        #expect(try await listed(router).contains("list_calls"))
        router.switches.disabled = Set(MCPServer.toolCatalog.map(\.name))
        #expect(try await listed(router).isEmpty)
    }

    @Test func aToolThatDoesNotExistIsStillUnknown() async throws {
        let reply = try await send(try router(disabled: ["nothing"]), "tools/call", ["name": "nothing"])
        let error = try #require(reply["error"] as? [String: Any])
        #expect((error["message"] as? String)?.contains("No tool") == true)
    }

    @Test func theCatalogGivesOneSentencePerTool() {
        let catalog = MCPServer.toolCatalog
        #expect(catalog.count > 10)
        #expect(catalog.allSatisfy { $0.summary.hasSuffix(".") && !$0.summary.dropLast().contains(".") })
    }
}

@Suite struct MCPEndpointTests {
    @Test func acceptsIPv4AndLocalhost() {
        #expect(MCPEndpoint.address(host: "127.0.0.1") == "127.0.0.1")
        #expect(MCPEndpoint.address(host: " localhost ") == "127.0.0.1")
        #expect(MCPEndpoint.address(host: "0.0.0.0") == "0.0.0.0")
        #expect(MCPEndpoint.address(host: "192.168.1.20") == "192.168.1.20")
    }

    @Test func refusesAnythingElse() {
        for host in ["", "example.com", "256.0.0.1", "1.2.3", "1.2.3.4.5", "::1", "1..3.4", "a.b.c.d", "127.0.0.1:80"] {
            #expect(MCPEndpoint.address(host: host) == nil, "\(host)")
        }
    }

    @Test func portsAreAboveTheReservedOnes() {
        #expect(MCPEndpoint.port("7766") == 7766)
        #expect(MCPEndpoint.port(" 8123 ") == 8123)
        for text in ["", "80", "1023", "65536", "-1", "port", "7766.5"] {
            #expect(MCPEndpoint.port(text) == nil, "\(text)")
        }
    }

    @Test func aServerListensOnTheAddressItIsGiven() async throws {
        let calls = try CallStore(url: temporaryCallDatabase())
        let server = MCPServer(store: calls, token: String(repeating: "ab", count: 32), port: 0, host: "localhost")
        defer { server.stop() }
        let port = try await server.start()
        #expect(port > 0)
    }

    @Test func aServerWithABadHostFailsToStart() async throws {
        let calls = try CallStore(url: temporaryCallDatabase())
        let server = MCPServer(store: calls, token: String(repeating: "ab", count: 32), port: 0, host: "nowhere")
        await #expect(throws: MCPServerError.self) { try await server.start() }
    }

    @Test func aDisabledToolIsRefusedOverHTTPToo() async throws {
        let calls = try CallStore(url: temporaryCallDatabase())
        let token = String(repeating: "ab", count: 32)
        let server = MCPServer(store: calls, token: token, port: 0, disabledTools: ["list_calls"])
        defer { server.stop() }
        let port = try await server.start()
        func call() async throws -> [String: Any] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "list_calls"]])
            let (data, _) = try await URLSession.shared.data(for: request)
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(try await call()["error"] != nil)
        server.disabledTools = []
        #expect(try await call()["error"] == nil)
    }
}

@Suite struct MCPTokenRegenerationTests {
    @Test func regeneratingReplacesTheTokenAndKeepsItPrivate() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "token-\(UUID().uuidString)")
        let url = folder.appending(path: "mcp-token")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try MCPToken.load(from: url)
        let second = try MCPToken.regenerate(at: url)
        #expect(first != second)
        #expect(second.count == 64)
        #expect(try MCPToken.load(from: url) == second)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".mcp-token-") }
        #expect(leftovers.isEmpty)
    }
}
