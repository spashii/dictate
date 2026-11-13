#if DEBUG
import AppKit
import SwiftUI
import VoiceCore

/// The app-shots run's drawings of the menu bar menu, the Model settings and the model picker.
extension Snapshots {
    // MARK: Menu bar menu

    /// Builds the real menu from `MenuContent` with the seeded recordings and draws it from its
    /// own items. AppKit cannot draw an NSMenu offscreen, so this replica is drawn from the
    /// real NSMenuItems: what the menu says is the app's, only the chrome is imitated.
    static func recentMenu(_ model: AppModel, store: CallStore, dictations: Store, dark: Bool) async -> NSBitmapImageRep? {
        let calls = CallsModel()
        calls.setRecentForSnapshots((try? store.recentCalls(limit: 4)) ?? [])
        model.recent = dictations.recent(5)
        model.setModelsForSnapshots(appleAvailable: true, ollama: ["qwen3.5:9b", "gemma3:4b"], choice: .apple)
        let menu = NSHostingMenu(rootView: MenuContent().environment(model).environment(calls))
        menu.update()
        return await drawMenu(ReplicaRow.rows(of: menu), width: 330, dark: dark)
    }

    // MARK: Model settings

    static func modelSettings(_ model: AppModel, appleAvailable: Bool, choice: LocalModel, dark: Bool) async throws -> NSBitmapImageRep? {
        model.setModelsForSnapshots(appleAvailable: appleAvailable, ollama: ["qwen3.5:9b", "gemma3:4b"], choice: choice)
        let navigation = MainNavigation()
        navigation.selection = .model
        let size = NSSize(width: 1060, height: 760)
        let window = makeWindow(MainView(navigation: navigation, history: HistoryModel()).environment(model)
            .environment(CallsModel()), size: size, dark: dark, titled: true)
        // A bitmap draw of the window leaves the grouped form blank, like the sidebar, so the pane
        // is drawn on its own and laid over the window's detail area.
        let paneSize = NSSize(width: size.width - 196, height: size.height - 52)
        let pane = makeWindow(ModelPane().environment(model).background(Color(nsColor: .windowBackgroundColor)),
                              size: paneSize, dark: dark, titled: false)
        try await Task.sleep(for: .seconds(2))
        guard let base = await capture(window, size: size, titled: true),
              let form = await capture(pane, size: paneSize, titled: false),
              let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: base.pixelsWide, pixelsHigh: base.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: out) else { return nil }
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        base.draw(in: NSRect(origin: .zero, size: size))
        form.draw(in: NSRect(origin: NSPoint(x: 196, y: 0), size: paneSize))
        // The window's own title strip is blank in a bitmap draw, and dark text on it would
        // vanish, so it is filled and titled here.
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(x: 196, y: size.height - 52, width: size.width - 196, height: 52).fill()
            NSColor.separatorColor.setFill()
            NSRect(x: 196, y: size.height - 52, width: size.width - 196, height: 0.5).fill()
            "Model".draw(at: NSPoint(x: 227, y: size.height - 33), withAttributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
        }
        NSGraphicsContext.restoreGraphicsState()
        return await withSidebar(out, model, .model, size: size, dark: dark)
    }

    /// The options the picker lists when Apple's model is there and Ollama has two.
    static func modelPicker(dark: Bool) async -> NSBitmapImageRep? {
        let rows: [ReplicaRow] = [
            .item(title: "Apple on-device", subtitle: nil, image: nil, enabled: true, key: nil, checked: true),
            .separator,
            .item(title: "qwen3.5:9b", subtitle: nil, image: nil, enabled: true, key: nil, checked: false),
            .item(title: "gemma3:4b", subtitle: nil, image: nil, enabled: true, key: nil, checked: false),
        ]
        return await drawMenu(rows, width: 220, dark: dark)
    }

    private static func drawMenu(_ rows: [ReplicaRow], width: CGFloat, dark: Bool) async -> NSBitmapImageRep? {
        let margin: CGFloat = 36
        let size = NSSize(width: width + margin * 2, height: ReplicaRow.height(of: rows) + margin * 2)
        let view = Backdrop(dark: dark) { MenuReplica(rows: rows, dark: dark).frame(width: width) }
        return await capture(makeWindow(view, size: size, dark: dark, titled: false), size: size, titled: false)
    }
}

/// One row of a menu, as drawn.
enum ReplicaRow {
    case item(title: String, subtitle: String?, image: NSImage?, enabled: Bool, key: String?, checked: Bool)
    case header(String)
    case separator

    var height: CGFloat {
        switch self {
        case .item(_, let subtitle, _, _, _, _): subtitle == nil ? 22 : 36
        case .header: 26
        case .separator: 11
        }
    }

    static func height(of rows: [ReplicaRow]) -> CGFloat { rows.reduce(10) { $0 + $1.height } }

    /// AppKit drops a separator that opens, closes or follows another one.
    static func rows(of menu: NSMenu) -> [ReplicaRow] {
        var rows = items(of: menu)
        var kept: [ReplicaRow] = []
        for row in rows {
            if case .separator = row, kept.isEmpty || { if case .separator = kept.last! { true } else { false } }() { continue }
            kept.append(row)
        }
        rows = kept
        while case .separator? = rows.last { rows.removeLast() }
        return rows
    }

    private static func items(of menu: NSMenu) -> [ReplicaRow] {
        menu.items.map { item in
            if item.isSeparatorItem { return .separator }
            if item.isSectionHeader { return .header(item.title) }
            return .item(title: item.title, subtitle: item.subtitle, image: item.image, enabled: item.isEnabled,
                         key: shortcut(item), checked: item.state == .on)
        }
    }

    private static func shortcut(_ item: NSMenuItem) -> String? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        let mask = item.keyEquivalentModifierMask
        var text = ""
        if mask.contains(.control) { text += "\u{2303}" }
        if mask.contains(.option) { text += "\u{2325}" }
        if mask.contains(.shift) { text += "\u{21E7}" }
        if mask.contains(.command) { text += "\u{2318}" }
        return text + item.keyEquivalent.uppercased()
    }
}

/// A macOS 26 style menu: a rounded panel with a thin border and a soft shadow, the menu font,
/// 22 point rows, taller ones for a subtitle, 5 points of padding inside.
private struct MenuReplica: View {
    let rows: [ReplicaRow]
    let dark: Bool

    private var font: Font { Font(NSFont.menuFont(ofSize: 0)) }
    private var hasImages: Bool {
        rows.contains { if case .item(_, _, let image, _, _, let checked) = $0 { image != nil || checked } else { false } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                switch row {
                case .separator:
                    Rectangle().fill(Color.primary.opacity(dark ? 0.16 : 0.12)).frame(height: 1)
                        .padding(.horizontal, 10).frame(height: row.height)
                case .header(let title):
                    Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.top, 6)
                        .frame(maxWidth: .infinity, maxHeight: row.height, alignment: .leading)
                case .item(let title, let subtitle, let image, let enabled, let key, let checked):
                    HStack(spacing: 6) {
                        if hasImages {
                            Group {
                                if let image {
                                    Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
                                } else if checked {
                                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                                }
                            }
                            .frame(width: 16, height: 16)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(title).font(font).lineLimit(1).truncationMode(.tail)
                            if let subtitle {
                                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.tail)
                            }
                        }
                        Spacer(minLength: 12)
                        if let key { Text(key).font(font).foregroundStyle(.secondary) }
                    }
                    .foregroundStyle(enabled ? Color.primary : Color.primary.opacity(0.3))
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: row.height, maxHeight: row.height, alignment: .leading)
                }
            }
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(dark ? Color(red: 0.18, green: 0.18, blue: 0.19).opacity(0.94) : Color(white: 0.97).opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(dark ? Color.white.opacity(0.16) : Color.black.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(dark ? 0.5 : 0.25), radius: 10, y: 5)
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}
#endif
