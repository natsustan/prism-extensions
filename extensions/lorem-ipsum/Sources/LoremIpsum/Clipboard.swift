import AppKit

/// Writes text to the general pasteboard.
protocol Clipboard: Sendable {
    func copy(_ text: String) async
}

struct SystemClipboard: Clipboard {
    @MainActor
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
