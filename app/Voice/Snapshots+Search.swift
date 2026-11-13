#if DEBUG
import AppKit

extension Snapshots {
    /// Where the toolbar's New button (the item furthest right) and its search field sit in the window, in points from its top left,
    /// as AppKit laid them out.
    static func toolbarFrames(_ window: NSWindow, height: CGFloat) async -> (plus: NSRect?, search: NSRect?) {
        try? await Task.sleep(for: .milliseconds(800))
        var plus: NSRect?
        var search: NSRect?
        func walk(_ view: NSView) {
            let name = String(describing: type(of: view))
            let frame = view.convert(view.bounds, to: nil)
            let top = NSRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
            if name == "NSSearchField" { search = top }
            if name.hasPrefix("ToolbarItemHostingView"), top.minX > (plus?.minX ?? 0) { plus = top }
            view.subviews.forEach(walk)
        }
        if let root = window.contentView?.superview { walk(root) }
        return (plus, search)
    }

    /// Drags the divider between the list and the detail, to show the list at its narrowest and widest.
    static func widenList(_ window: NSWindow, to width: CGFloat) {
        func walk(_ view: NSView) {
            // The pane's own split runs under the sidebar, so its divider sits the sidebar's width further right.
            if let split = view as? NSSplitView, split.isVertical, split.subviews.count == 3 {
                split.setPosition(208 + width, ofDividerAt: 0)
                split.layoutSubtreeIfNeeded()
            }
            view.subviews.forEach(walk)
        }
        if let root = window.contentView { walk(root) }
    }

    /// A bitmap draw of the window leaves the toolbar's search field without its capsule, so the
    /// capsule, the magnifier and the text are drawn over it the way the + is.
    static func withSearchField(_ window: NSBitmapImageRep?, frame: NSRect, text: String, size: NSSize,
                                dark: Bool) -> NSBitmapImageRep? {
        guard let window,
              let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: window.pixelsWide, pixelsHigh: window.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: out) else { return window }
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        window.draw(in: NSRect(origin: .zero, size: size))
        let box = NSRect(x: frame.minX, y: size.height - frame.maxY, width: frame.width, height: frame.height)
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            let capsule = NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: dark ? 0.35 : 0.12)
            shadow.shadowBlurRadius = 4
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
            (dark ? NSColor(white: 0.24, alpha: 1) : NSColor(white: 0.985, alpha: 1)).setFill()
            capsule.fill()
            NSGraphicsContext.restoreGraphicsState()
            (dark ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.1)).setStroke()
            capsule.lineWidth = 0.5
            capsule.stroke()
            let tint = dark ? NSColor(white: 1, alpha: 0.6) : NSColor(white: 0, alpha: 0.5)
            if let symbol = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) {
                let tinted = NSImage(size: symbol.size, flipped: false) { rect in
                    symbol.draw(in: rect)
                    tint.setFill()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(at: NSPoint(x: box.minX + 12, y: box.midY - symbol.size.height / 2), from: .zero, operation: .sourceOver, fraction: 1)
            }
            let shown = text.isEmpty ? "Search" : text
            let color = text.isEmpty ? tint : (dark ? NSColor.white : NSColor.black)
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: color]
            let line = NSAttributedString(string: shown, attributes: attributes)
            line.draw(at: NSPoint(x: box.minX + 36, y: box.midY - line.size().height / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
        return out
    }
}
#endif
