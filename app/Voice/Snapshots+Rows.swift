import AppKit
import VoiceCore
#if DEBUG
import SwiftUI

private struct SnapshotHoverKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

extension EnvironmentValues {
    /// The id of the transcript block drawn hovered, set only by app-shots: their windows sit
    /// far from the pointer, so no block would show its play mark.
    var snapshotHover: Int? {
        get { self[SnapshotHoverKey.self] }
        set { self[SnapshotHoverKey.self] = newValue }
    }
}
#endif

#if DEBUG
extension Snapshots {
    /// History with the seeded untitled call shown as being named.
    static func namingWindow(_ model: AppModel, store: CallStore, dark: Bool) async throws -> NSBitmapImageRep? {
        let calls = CallsModel()
        calls.setNamingForSnapshots(["short"])
        return try await historyWindow(model, HistoryModel(store: store), calls: calls, dark: dark)
    }

    /// History with the second transcript block drawn hovered.
    static func transcriptHoverWindow(_ model: AppModel, store: CallStore, dark: Bool) async throws -> NSBitmapImageRep? {
        let navigation = MainNavigation()
        navigation.selection = .history
        let size = NSSize(width: 1060, height: 680)
        let history = HistoryModel(store: store)
        let window = makeWindow(MainView(navigation: navigation, history: history).environment(model)
            .environment(CallsModel()).environment(\.snapshotHover, 1), size: size, dark: dark, titled: true)
        history.reload()
        for _ in 0..<40 where history.visible.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        guard let call = history.visible.first(where: { $0.id == "call:rollout" }) else {
            throw VoiceError.store("The seeded call is missing.")
        }
        history.selection = call.id
        history.select(call.id)
        for _ in 0..<40 where history.detail == nil || history.waveform.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        let sidebar = await withSidebar(await capture(window, size: size, titled: true), model, .history, size: size, dark: dark)
        return withPlusButton(sidebar, size: size, dark: dark)
    }
}
#endif
