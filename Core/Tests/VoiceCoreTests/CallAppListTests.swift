import Foundation
import Testing
@testable import VoiceCore

private func app(_ id: String, _ name: String, _ group: CallAppGroup, listening: Bool = false) -> RunningCallApp {
    RunningCallApp(bundleID: id, name: name, group: group, pid: 1, playing: false, listening: listening)
}

@Suite struct CallAppListTests {
    @Test func groupsKnownAppsAndLeavesTheRestToTheMicrophone() {
        #expect(CallAppGroup.of("us.zoom.xos", listening: false) == .communication)
        #expect(CallAppGroup.of("com.google.Chrome", listening: true) == .browsers)
        #expect(CallAppGroup.of("com.example.Notes", listening: false) == .other)
        #expect(CallAppGroup.of("com.example.Unknown", listening: true) == .communication)
        #expect(CallAppGroup.of("com.example.Browser", listening: false, browsers: ["com.example.Browser"]) == .browsers)
    }

    @Test func listsGroupsInOrderWithCallsFirstThenByName() {
        let grouped = RunningCallApp.grouped([
            app("o", "Notes", .other), app("b", "Safari", .browsers),
            app("c2", "Zoom", .communication), app("c1", "Discord", .communication),
            app("c3", "Other call", .communication, listening: true),
        ])
        #expect(grouped.map(\.group) == [.communication, .browsers, .other])
        #expect(grouped[0].apps.map(\.name) == ["Other call", "Discord", "Zoom"])
    }

    @Test func leavesOutEmptyGroups() {
        #expect(RunningCallApp.grouped([app("o", "Notes", .other)]).map(\.group) == [.other])
        #expect(RunningCallApp.grouped([]).isEmpty)
    }
}
