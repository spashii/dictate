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
        model.setModelsForSnapshots(apple: .available, ollama: ["qwen3.5:9b", "gemma3:4b"], choice: .apple)
        let menu = NSHostingMenu(rootView: MenuContent().environment(model).environment(calls))
        menu.update()
        return await drawMenu(ReplicaRow.rows(of: menu), dark: dark)
    }

    // MARK: History + menu

    /// History with the + menu open under its button, drawn from the real items the way the
    /// menu bar menu is. AppKit opens a menu below the button with its left edge on the button's,
    /// or against the window edge when it would run past it.
    static func plusMenu(_ model: AppModel, store: CallStore, dark: Bool) async throws -> NSBitmapImageRep? {
        let calls = CallsModel()
        let window = try await historyWindow(model, HistoryModel(store: store), calls: calls, dark: dark)
        let menu = NSHostingMenu(rootView: HistoryNewMenu(chooseFiles: {}).environment(model).environment(calls))
        menu.update()
        let rows = ReplicaRow.rows(of: menu)
        let width = ReplicaRow.width(of: rows), height = ReplicaRow.height(of: rows)
        let margin: CGFloat = 36
        let size = NSSize(width: width + margin * 2, height: height + margin * 2)
        let view = MenuReplica(rows: rows, dark: dark).frame(width: width).padding(margin)
            .background(Color(nsColor: .windowBackgroundColor))
        guard let window,
              let drawn = await capture(makeWindow(view, size: size, dark: dark, titled: false), size: size, titled: false),
              let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: window.pixelsWide, pixelsHigh: window.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: out) else { return nil }
        let windowSize = window.size
        out.size = windowSize
        let button = plusButton
        let left = min(button.minX, windowSize.width - 8 - width)
        // The panel sits 4 points under the button; its own margin holds the shadow.
        let origin = NSPoint(x: left - margin, y: windowSize.height - (button.maxY + 4) - height - margin)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        window.draw(in: NSRect(origin: .zero, size: windowSize))
        // The capture has a solid backing, so only the panel is kept, with the shadow drawn here.
        let panel = NSBezierPath(roundedRect: NSRect(x: origin.x + margin, y: origin.y + margin, width: width, height: height),
                                 xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: dark ? 0.5 : 0.25)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -5)
        shadow.set()
        NSColor.black.setFill()
        panel.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        panel.addClip()
        drawn.draw(in: NSRect(origin: origin, size: size))
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    // MARK: Model settings

    static func modelSettings(_ model: AppModel, apple: AppleModelState, ollama: [String]?, choice: LocalModel, dark: Bool) async throws -> NSBitmapImageRep? {
        model.setModelsForSnapshots(apple: apple, ollama: ollama, choice: choice)
        return try await settingsPane(model, .model, ModelPane(), size: NSSize(width: 1060, height: 760), dark: dark)
    }

    /// Settings, Agents with the server on and a fresh install's tool switches, tall enough to
    /// show the whole tool list.
    static func agentsSettings(_ model: AppModel, dark: Bool) async throws -> NSBitmapImageRep? {
        model.agents.holdForSnapshots()
        return try await settingsPane(model, .agents, AgentsPane(), size: NSSize(width: 1060, height: 1300), dark: dark)
    }

    /// Settings, About, tall enough to show the update and What's new, collapsed to the last
    /// three releases or expanded to all of them.
    static func aboutWindow(_ model: AppModel, expanded: Bool = false, dark: Bool) async throws -> NSBitmapImageRep? {
        try await settingsPane(model, .about, AboutPane(showingAllReleases: expanded),
                               size: NSSize(width: 1060, height: expanded ? 1900 : 1400), dark: dark)
    }

    private static func settingsPane<Pane: View>(_ model: AppModel, _ selection: MainPane, _ content: Pane,
                                                 size: NSSize, dark: Bool) async throws -> NSBitmapImageRep? {
        let navigation = MainNavigation()
        navigation.selection = selection
        let window = makeWindow(MainView(navigation: navigation, history: HistoryModel()).environment(model)
            .environment(CallsModel()), size: size, dark: dark, titled: true)
        // A bitmap draw of the window leaves the grouped form blank, like the sidebar, so the pane
        // is drawn on its own and laid over the window's detail area.
        let paneSize = NSSize(width: size.width - 196, height: size.height - 52)
        let pane = makeWindow(content.environment(model).background(Color(nsColor: .windowBackgroundColor)),
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
            selection.title.draw(at: NSPoint(x: 227, y: size.height - 33), withAttributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
        }
        NSGraphicsContext.restoreGraphicsState()
        return await withSidebar(out, model, selection, size: size, dark: dark)
    }

    /// The picker's popup for the state the model was last given, from the same option list the
    /// real row builds.
    static func modelPicker(_ model: AppModel, apple: AppleModelState, ollama: [String]?, choice: LocalModel, dark: Bool) async -> NSBitmapImageRep? {
        model.setModelsForSnapshots(apple: apple, ollama: ollama, choice: choice)
        let options = LocalModelChoice.pickerOptions(apple: apple, current: model.effectiveModel,
                                                     ollamaModels: ollama, ollamaModel: model.preferences.ollamaModel)
        func row(_ entry: LocalModelChoice.Options.Entry) -> ReplicaRow {
            .item(title: entry.title, subtitle: nil, image: nil, enabled: true, key: nil, checked: entry.model == model.effectiveModel)
        }
        return await drawMenu([row(options.apple), .separator] + options.ollama.map(row), dark: dark)
    }

    private static func drawMenu(_ rows: [ReplicaRow], dark: Bool) async -> NSBitmapImageRep? {
        let width = ReplicaRow.width(of: rows)
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

    /// The panel is as wide as its widest item, as an NSMenu is: image column, title, a gap and
    /// the shortcut, with 10 points either side and 5 of padding.
    static func width(of rows: [ReplicaRow]) -> CGFloat {
        let menuFont = NSFont.menuFont(ofSize: 0), small = NSFont.systemFont(ofSize: 11)
        func measure(_ text: String, _ font: NSFont) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
        let widest = rows.map { row -> CGFloat in
            switch row {
            case .item(let title, let subtitle, _, _, let key, _):
                let text = max(measure(title, menuFont), subtitle.map { measure($0, small) } ?? 0)
                return 16 + 6 + text + (key.map { 12 + measure($0, menuFont) } ?? 0)
            case .header(let title): return measure(title, .systemFont(ofSize: 11, weight: .semibold))
            case .separator: return 0
            }
        }.max() ?? 0
        return widest + 20 + 10 + 12 + 24
    }

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
                        // Every item keeps the image column, as in an NSMenu, so titles line up.
                        ZStack {
                            Color.clear
                            if let image {
                                Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
                            } else if checked {
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                            }
                        }
                        .frame(width: 16, height: 16)
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
