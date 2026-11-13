import Foundation

/// The panes of the main window: History in the Library, and the settings.
enum MainPane: String, CaseIterable, Identifiable {
    case welcome, history, setup, shortcuts, microphones, model, agents, advanced, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .history: "History"
        case .setup: "Setup"
        case .shortcuts: "Shortcuts"
        case .microphones: "Microphones"
        case .model: "Model"
        case .agents: "Agents"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .welcome: "hand.wave"
        case .history: "clock.arrow.circlepath"
        case .setup: "checkmark.circle"
        case .shortcuts: "keyboard"
        case .microphones: "mic"
        case .model: "waveform"
        case .agents: "terminal"
        case .advanced: "chart.xyaxis.line"
        case .about: "info.circle"
        }
    }

    /// Advanced is listed and reached only while developer mode is on.
    func shown(developerMode: Bool) -> Bool { self != .advanced || developerMode }

    static let library: [MainPane] = [.history]
    static let settings: [MainPane] = [.setup, .shortcuts, .microphones, .model, .agents, .advanced, .about]
}
