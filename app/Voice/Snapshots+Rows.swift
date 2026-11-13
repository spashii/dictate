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
