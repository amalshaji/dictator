import AppKit
import SwiftUI

@MainActor
struct HomeApplicationIdentity {
    let name: String
    let icon: NSImage?

    private struct Resolved {
        let name: String
        let icon: NSImage?
    }

    /// Resolving an app's display name and icon costs an `NSWorkspace` lookup, an
    /// `Info.plist` read, and an icon render, so repeated rows for the same app
    /// reuse the result instead of redoing that work on every render.
    private static var cache: [String: Resolved] = [:]

    init(bundleIdentifier: String) {
        if let cached = Self.cache[bundleIdentifier] {
            name = cached.name
            icon = cached.icon
            return
        }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        let bundle = url.flatMap(Bundle.init(url:))
        let resolvedName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url?.deletingPathExtension().lastPathComponent
            ?? bundleIdentifier.split(separator: ".").last.map(String.init)?.capitalized
            ?? bundleIdentifier
        let resolvedIcon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        name = resolvedName
        icon = resolvedIcon
        Self.cache[bundleIdentifier] = Resolved(name: resolvedName, icon: resolvedIcon)
    }
}

struct HomeApplicationIcon: View {
    let identity: HomeApplicationIdentity?
    var size: CGFloat = 38

    var body: some View {
        Group {
            if let icon = identity?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "app.dashed")
                    .font(DictatorDesign.glyphFont(size: size * 0.47, weight: .medium))
                    .foregroundStyle(DictatorDesign.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
