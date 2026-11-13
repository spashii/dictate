#if DEBUG
import AppKit
import SwiftUI

extension Snapshots {
    /// The History window with the confirmation a correction leaves, drawn over the transcript
    /// where the popover would sit. A popover doesn't draw in an offscreen window.
    static func keyTermAdded(_ model: AppModel, _ history: HistoryModel, dark: Bool) async throws -> NSBitmapImageRep? {
        guard let window = try await historyWindow(model, history, dark: dark) else { return nil }
        let card = KeyTermConfirmation(message: "Northwind is now a key term.", undo: {}, done: {})
            .frame(width: 250, height: 46)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.2)))
        let size = NSSize(width: 250, height: 46)
        let host = makeWindow(card, size: size, dark: dark, titled: false, active: true)
        guard let popover = await capture(host, size: size, titled: false),
              let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: window.pixelsWide, pixelsHigh: window.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: out) else {
            DevLog.write("app-shots: keyterm-added could not compose")
            return window
        }
        out.size = window.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        window.draw(in: NSRect(origin: .zero, size: window.size))
        let frame = NSRect(x: 640, y: 330, width: size.width, height: size.height)
        NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10).addClip()
        popover.draw(in: frame)
        NSGraphicsContext.restoreGraphicsState()
        return out
    }
}
#endif
