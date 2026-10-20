import AppKit

/// Asks the user to pick a color on screen; nil when they cancel.
protocol ColorSampling: Sendable {
    func sample() async -> RGBColor?
}

/// The system's magnifying loupe (`NSColorSampler`). The extension is a
/// command-line process with no running app, so this makes it an accessory
/// app and delivers the sampler's events itself until the user clicks or
/// presses Escape.
struct ScreenColorSampler: ColorSampling {
    @MainActor
    func sample() -> RGBColor? {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let result = SampleResult()
        // AppKit calls the handler on the main thread, from `sendEvent` below.
        NSColorSampler().show { color in
            MainActor.assumeIsolated {
                result.color = color
                result.isDone = true
            }
        }
        // Also stops when Prism cancels the command or it times out. The
        // loupe runs in a system service with no way to close it that ignores
        // events posted here, so it stays until the user clicks or presses
        // Escape, and that pick copies nothing.
        while !result.isDone, !Task.isCancelled {
            if let event = app.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.05), inMode: .default, dequeue: true) {
                app.sendEvent(event)
            }
        }
        guard !Task.isCancelled, let color = result.color?.usingColorSpace(.extendedSRGB) else { return nil }
        return RGBColor(
            red: color.redComponent, green: color.greenComponent, blue: color.blueComponent, alpha: color.alphaComponent
        )
    }

    @MainActor
    private final class SampleResult {
        var color: NSColor?
        var isDone = false
    }
}

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
