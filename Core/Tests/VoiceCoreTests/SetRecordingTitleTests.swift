import Foundation
import Testing
@testable import VoiceCore

@Suite struct SetRecordingTitleTests {
    private struct Fixture {
        var store: CallStore
        var url: URL
        var router: MCPRouter

        init(disabled: Set<String> = []) throws {
            url = temporaryCallDatabase()
            store = try CallStore(url: url)
            router = MCPRouter(store: store, recording: nil, recordingUnavailable: "", version: "0",
                               switches: ToolSwitches(disabled: disabled))
        }

        func send(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
            let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
            let (_, answer) = await router.handle(body)
            let data = try #require(answer)
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        /// The tool's JSON answer, and whether it was an error.
        func tool(_ name: String, _ arguments: [String: Any]) async throws -> (Any?, Bool, String) {
            let reply = try await send("tools/call", ["name": name, "arguments": arguments])
            let result = try #require(reply["result"] as? [String: Any])
            let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
            return (try? JSONSerialization.jsonObject(with: Data(text.utf8)), result["isError"] as? Bool ?? false, text)
        }
    }

    @Test func aNewInstallDoesNotOfferIt() async throws {
        let store = UserDefaults(suiteName: "dictate-tests-\(UUID().uuidString)")!
        #expect(MCPServer.offByDefault.contains("set_recording_title"))
        let fixture = try Fixture(disabled: AgentSettings.disabledTools(in: store, existingInstall: false))
        let reply = try await fixture.send("tools/list")
        let tools = ((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        #expect(!tools.contains("set_recording_title"))
        #expect(MCPServer.toolCatalog.first { $0.name == "set_recording_title" }?.summary.hasSuffix("date.") == true)
    }

    @Test func itRefusesCallsWhileOff() async throws {
        let fixture = try Fixture(disabled: ["set_recording_title"])
        let call = try fixture.store.createCall(NewCall(split: true))
        let reply = try await fixture.send("tools/call", ["name": "set_recording_title",
                                                          "arguments": ["id": call.id, "title": "Northwind rollout"]])
        let error = try #require(reply["error"] as? [String: Any])
        #expect((error["message"] as? String)?.contains("turned off") == true)
        #expect(try fixture.store.call(call.id)?.title == nil)
    }

    @Test func itTitlesACallAsTheAgentAndUndoRestoresIt() async throws {
        let fixture = try Fixture()
        let call = try fixture.store.createCall(NewCall(split: true))
        let (answer, failed, _) = try await fixture.tool("set_recording_title", ["id": call.id, "title": "Northwind rollout with Alex"])
        #expect(!failed)
        let object = try #require(answer as? [String: Any])
        #expect(object["id"] as? String == call.id)
        #expect(object["kind"] as? String == "call")
        #expect(object["title"] as? String == "Northwind rollout with Alex")
        #expect(object["title_source"] as? String == "agent")
        let editID = try #require(object["edit_id"] as? Int)

        let stored = try #require(try fixture.store.call(call.id))
        #expect(stored.title == "Northwind rollout with Alex" && stored.titleSource == .agent)

        let (log, _, _) = try await fixture.tool("list_edits", [:])
        let kinds = (log as? [[String: Any]] ?? []).compactMap { $0["kind"] as? String }
        #expect(kinds == ["rename_recording"])

        let (_, undoFailed, _) = try await fixture.tool("undo_edit", ["id": editID])
        #expect(!undoFailed)
        #expect(try fixture.store.call(call.id)?.title == nil)
    }

    @Test func itReplacesAPersonsTitle() async throws {
        let fixture = try Fixture()
        let call = try fixture.store.createCall(NewCall(split: true, title: "Lakeside kickoff"))
        #expect(call.titleSource == .user)
        let (answer, failed, _) = try await fixture.tool("set_recording_title", ["id": call.id, "title": "Lakeside kickoff with Alex"])
        #expect(!failed)
        #expect((answer as? [String: Any])?["title_source"] as? String == "agent")
        #expect(try fixture.store.call(call.id)?.title == "Lakeside kickoff with Alex")
    }

    @Test func itTitlesADictation() async throws {
        let fixture = try Fixture()
        let dictation = sampleDictation("send the plan to the team")
        try Store(url: fixture.url).insert(dictation)
        let (answer, failed, _) = try await fixture.tool("set_recording_title", ["id": dictation.id, "title": "Plan for Northwind"])
        #expect(!failed)
        let object = try #require(answer as? [String: Any])
        #expect(object["kind"] as? String == "dictation")
        #expect(object["title_source"] as? String == "agent")
        #expect(try fixture.store.recordingTitle(.dictation, dictation.id)?.title == "Plan for Northwind")
    }

    @Test func itTrimsAndCollapsesWhitespace() async throws {
        let fixture = try Fixture()
        let call = try fixture.store.createCall(NewCall(split: true))
        let (answer, failed, _) = try await fixture.tool("set_recording_title",
                                                         ["id": call.id, "title": "  Northwind \n\n rollout\t with   Alex \n"])
        #expect(!failed)
        #expect((answer as? [String: Any])?["title"] as? String == "Northwind rollout with Alex")
        #expect(try fixture.store.call(call.id)?.title == "Northwind rollout with Alex")
    }

    @Test func itAnswersWithoutAnEditWhenNothingChanged() async throws {
        let fixture = try Fixture()
        let call = try fixture.store.createCall(NewCall(split: true))
        _ = try await fixture.tool("set_recording_title", ["id": call.id, "title": "Northwind"])
        let (answer, failed, _) = try await fixture.tool("set_recording_title", ["id": call.id, "title": "Northwind"])
        #expect(!failed)
        #expect((answer as? [String: Any])?["edit_id"] == nil)
    }

    @Test func itRefusesAnEmptyTitleAndOneOverTheLimit() async throws {
        let fixture = try Fixture()
        let call = try fixture.store.createCall(NewCall(split: true, title: "Lakeside kickoff"))
        let (_, emptyFailed, empty) = try await fixture.tool("set_recording_title", ["id": call.id, "title": " \n "])
        #expect(emptyFailed && empty.contains("title is empty"))
        let (_, longFailed, long) = try await fixture.tool("set_recording_title",
                                                           ["id": call.id, "title": String(repeating: "a", count: 101)])
        #expect(longFailed && long.contains("101"))
        let (_, okFailed, _) = try await fixture.tool("set_recording_title",
                                                      ["id": call.id, "title": String(repeating: "a", count: 100)])
        #expect(!okFailed)
        let (_, missingFailed, _) = try await fixture.tool("set_recording_title", ["id": call.id])
        #expect(missingFailed)
    }

    @Test func itRefusesAnUnknownId() async throws {
        let fixture = try Fixture()
        let (_, failed, text) = try await fixture.tool("set_recording_title", ["id": "nope", "title": "Northwind"])
        #expect(failed && text.contains("No call or dictation nope"))
    }
}
