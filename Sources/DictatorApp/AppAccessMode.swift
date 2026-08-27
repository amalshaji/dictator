import Foundation

enum AppAccessMode: String, CaseIterable, Identifiable {
    case leastPrivileges
    case systemWide

    var id: String { rawValue }

    var allowsGlobalShortcuts: Bool { self == .systemWide }
    var allowsFocusedInsertion: Bool { self == .systemWide }
    var allowsScreenAwareDictation: Bool { self == .systemWide }
    var deliversToClipboard: Bool { self == .leastPrivileges }
}
