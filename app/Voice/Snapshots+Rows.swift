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
        try await historyWindow(model, HistoryModel(store: store), selecting: "call:rollout", hover: 1, dark: dark)
    }
}
#endif
