import Foundation

enum AppAccessMode: String, CaseIterable, Identifiable {
    case leastPrivileges
    case systemWide

    var id: String { rawValue }

    var allowsGlobalShortcuts: Bool { self == .systemWide }
    var allowsFocusedInsertion: Bool { self == .systemWide }
    var allowsScreenAwareDictation: Bool { self == .systemWide }
    var deliversToClipboard: Bool { self == .leastPrivileges }

    var title: String {
        switch self {
        case .leastPrivileges: "Use with least privileges"
        case .systemWide: "Use system-wide"
        }
    }

    var statusTitle: String {
        switch self {
        case .leastPrivileges: "Microphone only"
        case .systemWide: "System-wide enabled"
        }
    }

    var detail: String {
        switch self {
        case .leastPrivileges:
            "Record from the menu bar and copy every transcript to the clipboard. Dictator does not request Accessibility, Input Monitoring, or Screen Recording."
        case .systemWide:
            "Enable global shortcuts, focused-field insertion, and optional screen-aware dictation. Additional macOS permissions are required."
        }
    }

    var recordingInstruction: String {
        switch self {
        case .leastPrivileges: "Start from the menu bar, stop from the pill, then press ⌘V to paste."
        case .systemWide: "Use your Dictator shortcut to start and stop recording."
        }
    }
}
