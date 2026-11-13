import Foundation
import Testing
@testable import VoiceCore

@Suite struct TitleSourceTests {
    private func store() throws -> (CallStore, URL) {
        let url = temporaryCallDatabase()
        return (try CallStore(url: url), url)
    }

    @Test func anAutoTitleFillsAnUntitledCall() throws {
        let (calls, _) = try store()
        let call = try calls.createCall(NewCall(split: true))
        #expect(call.title == nil && call.titleSource == nil)

        #expect(try calls.setAutoTitle(call.id, "Northwind rollout with Alex"))

        let read = try #require(try calls.call(call.id))
        #expect(read.title == "Northwind rollout with Alex")
        #expect(read.titleSource == .auto)
        // Not an edit: nothing for undo_edit to revert.
        #expect(try calls.edits().isEmpty)
    }

    @Test func anAutoTitleNeverReplacesAnotherOrACleared() throws {
        let (calls, _) = try store()
        let user = try calls.createCall(NewCall(split: true, title: "Lakeside kickoff"))
        let agent = try calls.createCall(NewCall(split: true, title: "Agent name", titleSource: .agent))
        let cleared = try calls.createCall(NewCall(split: true))
        try calls.rename(.call, cleared.id, to: "Temporary")
        try calls.rename(.call, cleared.id, to: nil)

        for id in [user.id, agent.id, cleared.id] {
            #expect(try calls.setAutoTitle(id, "Something automatic") == false)
        }
        #expect(try calls.call(user.id)?.title == "Lakeside kickoff")
        #expect(try calls.call(agent.id)?.title == "Agent name")
        let after = try #require(try calls.call(cleared.id))
        #expect(after.title == nil)
        #expect(after.titleSource == .user)
        // A second automatic title doesn't replace the first either.
        let fresh = try calls.createCall(NewCall(split: true))
        #expect(try calls.setAutoTitle(fresh.id, "First"))
        #expect(try calls.setAutoTitle(fresh.id, "Second") == false)
        #expect(try calls.call(fresh.id)?.title == "First")
    }

    @Test func aRenameAfterAnAutoTitleWinsAndMarksTheClient() throws {
        let (calls, _) = try store()
        let call = try calls.createCall(NewCall(split: true))
        try calls.setAutoTitle(call.id, "Automatic")

        try calls.rename(.call, call.id, to: "Mine")
        #expect(try calls.call(call.id)?.titleSource == .user)
        try calls.rename(.call, call.id, to: "Agent's", client: "agent 1")
        let read = try #require(try calls.call(call.id))
        #expect(read.title == "Agent's")
        #expect(read.titleSource == .agent)
    }

    @Test func undoingARenameRestoresTheTextAndTheEarlierSource() throws {
        let (calls, _) = try store()
        let call = try calls.createCall(NewCall(split: true))
        try calls.setAutoTitle(call.id, "Automatic")
        let edit = try #require(try calls.rename(.call, call.id, to: "Changed", client: "agent 1"))
        #expect(try calls.call(call.id)?.titleSource == .agent)

        // The person undoing doesn't make the earlier automatic title theirs.
        try calls.undo(edit.id, client: Edit.personClient)
        let read = try #require(try calls.call(call.id))
        #expect(read.title == "Automatic")
        #expect(read.titleSource == .auto)

        let mine = try #require(try calls.rename(.call, call.id, to: "Mine"))
        let again = try #require(try calls.rename(.call, call.id, to: "Third", client: "agent 1"))
        try calls.undo(again.id, client: "agent 1")
        #expect(try calls.call(call.id)?.titleSource == .user)
        try calls.undo(mine.id, client: "agent 1")
        #expect(try calls.call(call.id)?.titleSource == .auto)
    }

    @Test func undoingATitleGivenToAnUntitledCallRestoresNoSource() throws {
        let (calls, _) = try store()
        let call = try calls.createCall(NewCall(split: true))
        let edit = try #require(try calls.rename(.call, call.id, to: "Named", client: "agent 1"))
        try calls.undo(edit.id, client: Edit.personClient)
        let read = try #require(try calls.call(call.id))
        #expect(read.title == nil && read.titleSource == nil)
    }

    @Test func editsStoredWithoutASourceStillDecode() throws {
        let old = Data(#"{"text":"Old"}"#.utf8)
        let value = try JSONDecoder().decode(Edit.Value.self, from: old)
        #expect(value.text == "Old" && value.source == nil)
        let round = try JSONDecoder().decode(Edit.Value.self, from: JSONEncoder().encode(Edit.Value(text: "x", source: "auto")))
        #expect(round.source == "auto")
    }

    @Test func aDictationsTitleHasASourceToo() throws {
        let (calls, url) = try store()
        let dictation = sampleDictation("send the plan to the team")
        try Store(url: url).insert(dictation)
        try calls.rename(.dictation, dictation.id, to: "Plan", client: "agent 1")
        #expect(try SQLiteConnection(url: url).query("SELECT title_source FROM dictations WHERE id = ?", [dictation.id]) {
            $0.string(0)
        }.first == "agent")
    }

    @Test func theMigrationMarksExistingTitlesAsAPersons() throws {
        let url = temporaryCallDatabase()
        let dictation = sampleDictation("send the plan to the team")
        do {
            let calls = try CallStore(url: url)
            try calls.createCall(NewCall(id: "titled", split: true))
            try calls.createCall(NewCall(id: "plain", split: true))
            try Store(url: url).insert(dictation)
        }
        // The file as it was before titles-2: a title, no source column.
        let raw = try SQLiteConnection(url: url)
        try raw.exec("""
            ALTER TABLE calls DROP COLUMN title_source;
            ALTER TABLE dictations DROP COLUMN title_source;
            UPDATE calls SET title = 'Old name' WHERE id = 'titled';
            UPDATE dictations SET title = 'Old dictation' WHERE id = '\(dictation.id)';
            DELETE FROM voice_migrations WHERE name = 'titles-2';
            """)

        let opened = try CallStore(url: url)

        #expect(try opened.call("titled")?.titleSource == .user)
        #expect(try opened.call("plain")?.titleSource == nil)
        let sources = try SQLiteConnection(url: url).query("SELECT title_source FROM dictations") { $0.string(0) }
        #expect(sources == ["user"])
        // Nothing left to title: the untitled call can still be filled, the titled one can't.
        #expect(try opened.setAutoTitle("titled", "New") == false)
        #expect(try opened.setAutoTitle("plain", "New"))
    }

    @Test func historySearchFindsACallByAnAutoTitleWord() throws {
        let (calls, _) = try store()
        let call = try calls.createCall(NewCall(appName: "Slack", split: true))
        try calls.appendSegments(call.id, [sampleSegment(.me, 0, "we talked about the budget for the pilot")])
        try calls.setAutoTitle(call.id, "Lakeside rollout with Alex")

        // "rollout" is in the title and nowhere in the transcript.
        #expect(try calls.historyEntries(matching: "rollout").map(\.ref) == [call.id])
        #expect(try calls.historyEntries(matching: "budget").map(\.ref) == [call.id])
        let entry = try #require(try calls.historyEntries().first)
        #expect(entry.customTitle == "Lakeside rollout with Alex")
    }

    @Test func aCallCreatedWithATitleRecordsWhoGaveIt() throws {
        let (calls, _) = try store()
        let person = try calls.createCall(NewCall(split: true, title: "Mine"))
        let agent = try calls.createCall(NewCall(split: true, title: "Theirs", titleSource: .agent))
        let none = try calls.createCall(NewCall(split: true, titleSource: .agent))
        #expect(person.titleSource == .user)
        #expect(agent.titleSource == .agent)
        #expect(none.titleSource == nil)
    }
}
