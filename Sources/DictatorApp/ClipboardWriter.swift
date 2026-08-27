import AppKit

@MainActor
protocol ClipboardWriting: AnyObject {
    func write(_ text: String) -> Bool
}

@MainActor
final class SystemClipboardWriter: ClipboardWriting {
    func write(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
