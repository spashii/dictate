import CoreGraphics

/// A live pill fades while the pointer is over it, so the text under it can be read. The
/// pills sit in a panel that ignores the mouse, so views can't report hovering; the pointer
/// is compared with where each pill is instead.
enum PillHover {
    /// How much of the pill is left while the pointer is over it.
    static let dimmedOpacity = 0.25
    static let fade = 0.18

    static func opacity(hovered: Bool) -> Double {
        hovered ? dimmedOpacity : 1
    }

    /// Whether the pointer, in the same coordinates as the frames, is over one of them.
    static func isOver(_ pointer: CGPoint, frames: [CGRect]) -> Bool {
        frames.contains { $0.contains(pointer) }
    }

    /// The pointer in the panel's own coordinates, with the origin at its top left, from a
    /// screen position, whose origin is the bottom left.
    static func inPanel(_ pointer: CGPoint, panel: CGRect) -> CGPoint {
        CGPoint(x: pointer.x - panel.minX, y: panel.maxY - pointer.y)
    }
}
