import Foundation

/// Resolves which writing style applies to a dictation, based on the
/// user's selected global style.
public enum StyleResolver {
    public static func styleID(
        styles: [WritingStyle],
        globalStyleID: UUID?
    ) -> UUID? {
        if let globalStyleID,
           styles.contains(where: { $0.id == globalStyleID && $0.isEnabled }) {
            return globalStyleID
        }
        return nil
    }

    public static func instruction(
        styles: [WritingStyle],
        globalStyleID: UUID?
    ) -> String? {
        styleID(styles: styles, globalStyleID: globalStyleID)
            .flatMap { id in styles.first { $0.id == id }?.instruction }
    }
}
