import Foundation
import PrismExtensionKit

/// Keeps the Mac awake through `/usr/bin/caffeinate`. Prism starts the
/// process as a host task (`task.start`), so it outlives both this extension
/// and Prism itself. State is read from the system on every request and covers
/// caffeinate processes started outside Prism too; nothing is saved.
@main
struct Caffeinate: PrismExtension {
    enum CommandID {
        static let caffeinate = "caffeinate"
        static let status = "caffeinate-status"
        static let decaffeinate = "decaffeinate"
        static let toggle = "toggle-caffeinate"
    }

    static let taskID = "caffeinate"
    static let widgetID = "toggle"

    let processes: any CaffeinateProcesses
    /// How long a start may take to show up: Prism launches the task after
    /// this request asks for it.
    let startTimeout: Duration
    let pollInterval: Duration

    init() {
        self.init(processes: SystemCaffeinateProcesses())
    }

    init(
        processes: any CaffeinateProcesses,
        startTimeout: Duration = .seconds(2),
        pollInterval: Duration = .milliseconds(100)
    ) {
        self.processes = processes
        self.startTimeout = startTimeout
        self.pollInterval = pollInterval
    }

    /// A visible status row or widget follows processes started or stopped
    /// elsewhere.
    var statusRefreshInterval: Duration? { .seconds(2) }

    func run(command: String, context: PrismContext) async throws -> ExtensionCommandResult {
        switch command {
        case CommandID.caffeinate:
            return try await start(context)
        case CommandID.status:
            return .keepOpen(message: processes.isRunning() ? String(localized: "Caffeinate is on.", bundle: .module.prismLocalized) : String(localized: "Caffeinate is off.", bundle: .module.prismLocalized))
        case CommandID.decaffeinate:
            return try stop()
        case CommandID.toggle:
            return try await processes.isRunning() ? stop() : start(context)
        default:
            throw PrismExtensionError(String(localized: "This Caffeinate command is not available.", bundle: .module.prismLocalized))
        }
    }

    func status(for command: String, context: PrismContext) async throws -> ExtensionRowStatus? {
        guard command == CommandID.status else { return nil }
        return processes.isRunning()
            ? ExtensionRowStatus(text: String(localized: "Caffeinated", bundle: .module.prismLocalized), symbol: "checkmark", isLive: true)
            : ExtensionRowStatus(text: String(localized: "Decaffeinated", bundle: .module.prismLocalized), isLive: true)
    }

    func widget(_ widget: String, context: PrismContext) async throws -> ExtensionWidgetContent {
        guard widget == Self.widgetID else {
            throw PrismExtensionError(String(localized: "Caffeinate has no widget “\(widget)”.", bundle: .module.prismLocalized))
        }
        let isOn = processes.isRunning()
        return .toggleCard(ExtensionToggleCard(
            title: String(localized: "Keep Awake", bundle: .module.prismLocalized),
            status: isOn ? String(localized: "On", bundle: .module.prismLocalized) : String(localized: "Off", bundle: .module.prismLocalized),
            symbol: "cup.and.heat.waves.fill",
            tint: "orange",
            isOn: isOn,
            help: isOn ? String(localized: "Turn Caffeinate off", bundle: .module.prismLocalized) : String(localized: "Turn Caffeinate on", bundle: .module.prismLocalized),
            accessibilityLabel: isOn ? String(localized: "Keep Awake on, turn off", bundle: .module.prismLocalized) : String(localized: "Keep Awake off, turn on", bundle: .module.prismLocalized),
            toggleCommandID: CommandID.toggle
        ))
    }

    // MARK: - Starting and stopping

    private func start(_ context: PrismContext) async throws -> ExtensionCommandResult {
        guard !processes.isRunning() else {
            return .completed(message: String(localized: "Caffeinate is already on.", bundle: .module.prismLocalized), restoreFocus: true)
        }
        // -d keeps the display awake, -i the system; -m the disk, if asked.
        let arguments = ["-d", "-i"] + (context.preferences.bool("preventDiskSleep") ? ["-m"] : [])
        await context.startTask(Self.taskID, arguments: arguments)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: startTimeout)
        while clock.now < deadline {
            if processes.isRunning() {
                return .completed(message: String(localized: "Caffeinate is on.", bundle: .module.prismLocalized), restoreFocus: true)
            }
            try await Task.sleep(for: pollInterval)
        }
        return .failed(message: String(localized: "Caffeinate did not start.", bundle: .module.prismLocalized))
    }

    private func stop() throws -> ExtensionCommandResult {
        guard processes.isRunning() else {
            return .completed(message: String(localized: "Caffeinate is already off.", bundle: .module.prismLocalized), restoreFocus: true)
        }
        do {
            try processes.stopAll()
        } catch {
            return .failed(message: String(localized: "Could not stop caffeinate: \(error.localizedDescription)", bundle: .module.prismLocalized))
        }
        let message = processes.isRunning() ? String(localized: "Caffeinate is stopping.", bundle: .module.prismLocalized) : String(localized: "Caffeinate is off.", bundle: .module.prismLocalized)
        return .completed(message: message, restoreFocus: true)
    }
}
