import AppKit
import CoreGraphics
import Foundation

struct PasteboardSnapshot {
    struct Item { let values: [NSPasteboard.PasteboardType: Data] }
    let items: [Item]
}

@MainActor
protocol ClipboardAccess {
    func snapshot() -> PasteboardSnapshot
    func prepare(text: String, sessionID: String) -> Bool
    func owns(text: String, sessionID: String) -> Bool
    func restore(_ snapshot: PasteboardSnapshot)
}

struct PostedKeyEvent: Equatable {
    let keyCode: CGKeyCode
    let keyDown: Bool
    let flags: CGEventFlags
}

@MainActor
final class ClipboardPaster {
    private static let systemEventSource = CGEventSource(stateID: .combinedSessionState)

    private let clipboard: any ClipboardAccess
    private let postEvent: @MainActor (PostedKeyEvent) -> Bool
    private let delay: (Int) async -> Void
    private var pendingRestoreTask: Task<Void, Never>?
    private var pendingOriginalSnapshot: PasteboardSnapshot?

    init() {
        clipboard = SystemClipboardAccess()
        postEvent = Self.postSystemEvent
        delay = { try? await Task.sleep(for: .milliseconds($0)) }
    }

    init(
        clipboard: any ClipboardAccess,
        postEvent: @escaping @MainActor (PostedKeyEvent) -> Bool,
        delay: @escaping (Int) async -> Void
    ) {
        self.clipboard = clipboard
        self.postEvent = postEvent
        self.delay = delay
    }

    func paste(_ text: String) async -> Bool {
        // A restore still pending from an earlier, overlapping paste holds
        // the user's true original clipboard contents; the pasteboard right
        // now only holds that earlier paste's text, so reuse the pending
        // original instead of snapshotting the wrong "original".
        let snapshot = pendingOriginalSnapshot ?? clipboard.snapshot()
        let sessionID = UUID().uuidString
        guard clipboard.prepare(text: text, sessionID: sessionID) else {
            clipboard.restore(snapshot)
            cancelPendingRestore()
            return false
        }

        await delay(40)
        guard await postPasteCommand() else {
            restoreIfOwned(snapshot, text: text, sessionID: sessionID)
            cancelPendingRestore()
            return false
        }

        scheduleRestore(snapshot, text: text, sessionID: sessionID)
        return true
    }

    /// The pasteboard restore only needs to happen before the *next* copy, not
    /// before the paste command lands, so it runs after `paste` has already
    /// returned instead of holding up the `.processing` UI state.
    private func scheduleRestore(_ snapshot: PasteboardSnapshot, text: String, sessionID: String) {
        pendingRestoreTask?.cancel()
        pendingOriginalSnapshot = snapshot
        pendingRestoreTask = Task { @MainActor [weak self] in
            await self?.delay(500)
            guard let self, !Task.isCancelled else { return }
            self.restoreIfOwned(snapshot, text: text, sessionID: sessionID)
            self.pendingRestoreTask = nil
            self.pendingOriginalSnapshot = nil
        }
    }

    /// Drops the pending-restore bookkeeping for a paste whose own restore
    /// already ran synchronously (e.g. an immediate failure path), so a
    /// later paste doesn't reuse a stale snapshot or leave a superseded
    /// restore task around.
    private func cancelPendingRestore() {
        pendingRestoreTask?.cancel()
        pendingRestoreTask = nil
        pendingOriginalSnapshot = nil
    }

    private func postPasteCommand() async -> Bool {
        // Carry Command on the V events themselves. Separate modifier events can
        // make some web editors handle the same synthetic paste twice.
        let events = [
            PostedKeyEvent(keyCode: 0x09, keyDown: true, flags: .maskCommand),
            PostedKeyEvent(keyCode: 0x09, keyDown: false, flags: .maskCommand),
        ]

        for (index, event) in events.enumerated() {
            guard postEvent(event) else { return false }
            if index < events.count - 1 { await delay(15) }
        }
        return true
    }

    private func restoreIfOwned(_ snapshot: PasteboardSnapshot, text: String, sessionID: String) {
        guard clipboard.owns(text: text, sessionID: sessionID) else { return }
        clipboard.restore(snapshot)
    }

    private static func postSystemEvent(_ event: PostedKeyEvent) -> Bool {
        guard let source = systemEventSource,
              let cgEvent = CGEvent(
                keyboardEventSource: source,
                virtualKey: event.keyCode,
                keyDown: event.keyDown
              )
        else { return false }
        cgEvent.flags = event.flags
        cgEvent.post(tap: .cghidEventTap)
        return true
    }
}

@MainActor
private struct SystemClipboardAccess: ClipboardAccess {
    private static let sessionType = NSPasteboard.PasteboardType("ai.dictator.paste-session")
    private let pasteboard = NSPasteboard.general

    func snapshot() -> PasteboardSnapshot {
        PasteboardSnapshot(items: (pasteboard.pasteboardItems ?? []).map { item in
            PasteboardSnapshot.Item(values: Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            }))
        })
    }

    func prepare(text: String, sessionID: String) -> Bool {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string),
              item.setString(sessionID, forType: Self.sessionType)
        else { return false }
        return pasteboard.writeObjects([item])
    }

    func owns(text: String, sessionID: String) -> Bool {
        pasteboard.string(forType: .string) == text
            && pasteboard.string(forType: Self.sessionType) == sessionID
    }

    func restore(_ snapshot: PasteboardSnapshot) {
        pasteboard.clearContents()
        let items = snapshot.items.map { snapshotItem -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in snapshotItem.values { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
