import os

/// Agent Usage writes to the unified log under its own subsystem; Prism keeps
/// the process's stderr separately.
enum AgentUsageLog {
    static let logger = Logger(subsystem: "prism.agent-usage", category: "AgentUsage")
}
