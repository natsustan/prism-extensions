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
            return .keepOpen(message: processes.isRunning() ? localized("Caffeinate is on.") : localized("Caffeinate is off."))
        case CommandID.decaffeinate:
            return try stop()
        case CommandID.toggle:
            return try await processes.isRunning() ? stop() : start(context)
        default:
            throw PrismExtensionError(localized("This Caffeinate command is not available."))
        }
    }

    func status(for command: String, context: PrismContext) async throws -> ExtensionRowStatus? {
        guard command == CommandID.status else { return nil }
        return processes.isRunning()
            ? ExtensionRowStatus(text: localized("Caffeinated"), symbol: "checkmark", isLive: true)
            : ExtensionRowStatus(text: localized("Decaffeinated"), isLive: true)
    }

    func widget(_ widget: String, context: PrismContext) async throws -> ExtensionWidgetContent {
        guard widget == Self.widgetID else {
            throw PrismExtensionError(localized("Caffeinate has no widget “\(widget)”."))
        }
        let isOn = processes.isRunning()
        return .toggleCard(ExtensionToggleCard(
            title: localized("Keep Awake"),
            status: isOn ? localized("On") : localized("Off"),
            symbol: "cup.and.heat.waves.fill",
            tint: "orange",
            isOn: isOn,
            help: isOn ? localized("Turn Caffeinate off") : localized("Turn Caffeinate on"),
            accessibilityLabel: isOn ? localized("Keep Awake on, turn off") : localized("Keep Awake off, turn on"),
            toggleCommandID: CommandID.toggle
        ))
    }

    // MARK: - Starting and stopping

    private func start(_ context: PrismContext) async throws -> ExtensionCommandResult {
        guard !processes.isRunning() else {
            return .completed(message: localized("Caffeinate is already on."), restoreFocus: true)
        }
        // -d keeps the display awake, -i the system; -m the disk, if asked.
        let arguments = ["-d", "-i"] + (context.preferences.bool("preventDiskSleep") ? ["-m"] : [])
        await context.startTask(Self.taskID, arguments: arguments)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: startTimeout)
        while clock.now < deadline {
            if processes.isRunning() {
                return .completed(message: localized("Caffeinate is on."), restoreFocus: true)
            }
            try await Task.sleep(for: pollInterval)
        }
        return .failed(message: localized("Caffeinate did not start."))
    }

    private func stop() throws -> ExtensionCommandResult {
        guard processes.isRunning() else {
            return .completed(message: localized("Caffeinate is already off."), restoreFocus: true)
        }
        do {
            try processes.stopAll()
        } catch {
            return .failed(message: localized("Could not stop caffeinate: \(error.localizedDescription)"))
        }
        let message = processes.isRunning() ? localized("Caffeinate is stopping.") : localized("Caffeinate is off.")
        return .completed(message: message, restoreFocus: true)
    }
}
