import Foundation
import PrismExtensionKit

/// AI coding agents' quotas: a list command whose rows lead with each agent's
/// primary quota and whose detail breaks the report into sections, plus quota
/// widgets. Providers, fetching, throttling, and failure handling live in
/// `AgentUsageController`; `AgentUsagePresentation` turns its rows into
/// protocol values. Prism stops the process whenever it is idle, so the last
/// reports and the throttle survive in the extension's data directory.
@main
struct AgentUsage: PrismExtension {
    enum CommandID {
        static let usage = "usage"
    }

    enum PreferenceID {
        static let agents = "agents"
        static let showsRemaining = "showsRemaining"
        static let zaiKey = "zaiKey"
    }

    enum ActionID {
        static let refresh = "refresh"
        static let copySummary = "copy-summary"
    }

    let session: AgentUsageSession

    init() {
        self.init(session: AgentUsageSession())
    }

    init(session: AgentUsageSession) {
        self.session = session
    }

    func list(command: String, query: String, filter: String?, context: PrismContext) async throws -> ExtensionList {
        guard command == CommandID.usage else {
            throw PrismExtensionError("This Agent Usage list is not available.")
        }
        return await session.list(context)
    }

    func perform(action: String, item: String, command: String, context: PrismContext) async throws -> ExtensionActionResult {
        guard action == ActionID.refresh else {
            throw PrismExtensionError("This action is not available.")
        }
        await session.refresh(context)
        return ExtensionActionResult(.keepOpen(message: ""))
    }

    func widget(_ widget: String, context: PrismContext) async throws -> ExtensionWidgetContent {
        try await session.widget(widget, context: context)
    }

    func preferenceItems(_ preference: String, context: PrismContext) async throws -> [ExtensionPreferenceItem] {
        guard preference == PreferenceID.agents else { return [] }
        return await session.preferenceItems(context)
    }
}
