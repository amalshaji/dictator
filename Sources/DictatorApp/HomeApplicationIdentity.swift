import AppKit
import SwiftUI

@MainActor
struct HomeApplicationIdentity {
    let name: String
    let icon: NSImage?

    init(bundleIdentifier: String) {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        let bundle = url.flatMap(Bundle.init(url:))
        name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url?.deletingPathExtension().lastPathComponent
            ?? bundleIdentifier.split(separator: ".").last.map(String.init)?.capitalized
            ?? bundleIdentifier
        icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
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
                    .font(.system(size: size * 0.47, weight: .medium))
                    .foregroundStyle(DictatorDesign.muted)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
