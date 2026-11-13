#if DEBUG
import AppKit
import SwiftUI
import VoiceCore

/// The shots of the Data retention settings, the Developer mode confirmation and a recording
/// whose audio is gone. Nothing here launches the app's retention run or touches a real store:
/// the stored choices are set on the preferences and put back as they were.
extension Snapshots {
    static func retentionShots(_ model: AppModel, store: CallStore, into folder: URL, suffix: String, dark: Bool) async throws {
        let defaults = UserDefaults.standard
        let developerMode = model.preferences.developerMode
        let choices = RetentionChoices.load(from: defaults)
        defer {
            model.preferences.retentionChoices = choices
            model.preferences.developerMode = developerMode
        }
        let size = NSSize(width: 1060, height: 680)

        model.preferences.retentionChoices = RetentionChoices()
        model.preferences.developerMode = false
        await write(folder, "retention-settings-\(suffix)",
                    try await settingsPane(model, .setup, SetupPane(), size: size, dark: dark))
        let about = try await settingsPane(model, .about, AboutPane(), size: size, dark: dark)

        model.preferences.developerMode = true
        await write(folder, "retention-settings-devmode-\(suffix)",
                    try await settingsPane(model, .setup, SetupPane(), size: size, dark: dark))

        // The confirmation, for the defaults a person who turns Developer mode off would get.
        let policy = RetentionPolicy.effective(audio: .sevenDays, transcripts: .thirtyDays, developerMode: false)
        let text = RetentionText.turnOffDeveloperMode(counts: RetentionCounts(recordings: 42, audioOnly: 18), policy: policy)
        // Dark is not drawn: an alert window that is never shown paints its glass light, which hides its white text.
        if !dark {
            await write(folder, "retention-devmode-off-confirm-\(suffix)", sheet(AppModel.retentionAlert(text), over: about, size: size, dark: dark))
        }

        // A finished recording with its audio gone, in a seed of its own.
        let work = FileManager.default.temporaryDirectory.appending(path: "dictate-retention-shots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let (calls, _) = try Seed.make(in: work)
        _ = try calls.clearAudio("rollout")
        model.preferences.developerMode = false
        await write(folder, "history-audio-deleted-\(suffix)",
                    try await historyWindow(model, HistoryModel(store: calls), dark: dark))
    }

    /// The alert drawn as a sheet would sit: centred under the title bar of the window behind it.
    /// Laid out and drawn without being shown.
    private static func sheet(_ alert: NSAlert, over base: NSBitmapImageRep?, size: NSSize, dark: Bool) -> NSBitmapImageRep? {
        alert.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        alert.icon = NSApp.applicationIconImage
        alert.layout()
        guard let base, let frame = alert.window.contentView else { return nil }
        // An unshown window's material draws light in both appearances; the card gets its own fill below.
        func hideMaterial(_ view: NSView) {
            if view is NSVisualEffectView || String(describing: type(of: view)).contains("Glass") { view.isHidden = true }
            view.subviews.forEach(hideMaterial)
        }
        hideMaterial(frame.superview ?? frame)
        let bounds = frame.bounds
        guard let card = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width) * 2, pixelsHigh: Int(bounds.height) * 2,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: base.pixelsWide, pixelsHigh: base.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: out) else { return nil }
        card.size = bounds.size
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            frame.cacheDisplay(in: bounds, to: card)
        }
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        base.draw(in: NSRect(origin: .zero, size: size))
        let origin = NSPoint(x: 196 + (size.width - 196 - bounds.width) / 2, y: size.height - 52 - bounds.height)
        let rect = NSRect(origin: origin, size: bounds.size)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 20
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).addClip()
        card.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.restoreGraphicsState()
        return out
    }
}
#endif
