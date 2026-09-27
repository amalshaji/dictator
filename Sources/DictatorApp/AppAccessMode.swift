import Foundation

enum AppAccessMode: String, CaseIterable, Identifiable {
    case leastPrivileges
    case systemWide

    var id: String { rawValue }

    var allowsGlobalShortcuts: Bool { self == .systemWide }
    var allowsFocusedInsertion: Bool { self == .systemWide }
    var deliversToClipboard: Bool { self == .leastPrivileges }

    var title: String {
        switch self {
        case .leastPrivileges: "Use with least privileges"
        case .systemWide: "Use system-wide"
        }
    }

    var detail: String {
        switch self {
        case .leastPrivileges:
            "Record from the menu bar and copy every transcript to the clipboard. Dictator does not request Accessibility or Input Monitoring."
        case .systemWide:
            "Enable global shortcuts and focused-field insertion. Additional macOS permissions are required."
        }
    }
}

struct AppAccessConfiguration: Equatable {
    let mode: AppAccessMode
    let systemWideInsertionMode: InsertionMode

    var insertionMode: InsertionMode {
        mode.deliversToClipboard ? .clipboard : systemWideInsertionMode
    }

    func selectingAccessMode(_ mode: AppAccessMode) -> AppAccessConfiguration {
        AppAccessConfiguration(
            mode: mode,
            systemWideInsertionMode: systemWideInsertionMode
        )
    }

    func selectingSystemWideInsertionMode(_ insertionMode: InsertionMode) -> AppAccessConfiguration {
        AppAccessConfiguration(
            mode: mode,
            systemWideInsertionMode: insertionMode
        )
    }
}
