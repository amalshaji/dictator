import Foundation

/// Resolves which writing style applies to a dictation, preferring the
/// per-app override for the focused app over the global default style.
public enum StyleResolver {
    public static func styleID(
        forApp bundleID: String?,
        overrides: [String: UUID],
        styles: [WritingStyle],
        globalStyleID: UUID?
    ) -> UUID? {
        if let bundleID,
           let overrideID = overrides[bundleID],
           styles.contains(where: { $0.id == overrideID && $0.isEnabled }) {
            return overrideID
        }
        if let globalStyleID,
           styles.contains(where: { $0.id == globalStyleID && $0.isEnabled }) {
            return globalStyleID
        }
        return nil
    }

    public static func instruction(
        forApp bundleID: String?,
        overrides: [String: UUID],
        styles: [WritingStyle],
        globalStyleID: UUID?
    ) -> String? {
        styleID(forApp: bundleID, overrides: overrides, styles: styles, globalStyleID: globalStyleID)
            .flatMap { id in styles.first { $0.id == id }?.instruction }
    }
}
