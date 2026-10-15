import PrismExtensionKit

/// A minimal Prism extension in Swift. Each method answers one part of
/// manifest.json: `run` for commands, `status` for rows declared with
/// `"liveStatus": true`. Add `widget(_:context:)` for widgets.
@main
struct HelloSwift: PrismExtension {
    func run(command: String, context: PrismContext) async throws -> ExtensionCommandResult {
        switch command {
        case "greet":
            // State lives in Prism, so it survives the process being stopped.
            let count = (await context.state("greetings")?.numberValue ?? 0) + 1
            await context.setState(.number(count), for: "greetings")
            let mark = context.preferences.bool("excited") ? "!" : "."
            return .keepOpen(message: "Hello from Swift\(mark) That makes \(Int(count)).")
        case "reset":
            await context.setState(nil, for: "greetings")
            return .done
        default:
            throw PrismExtensionError("Unknown command \(command).")
        }
    }

    func status(for command: String, context: PrismContext) async throws -> ExtensionRowStatus? {
        let count = Int(await context.state("greetings")?.numberValue ?? 0)
        return ExtensionRowStatus(text: count == 1 ? "Greeted once" : "Greeted \(count) times", isLive: true)
    }
}
