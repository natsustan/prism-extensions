import Foundation

/// How long a refresh may take. A provider's required request runs up to the
/// refresh deadline; optional enrichment (reset credits, plan names) has to
/// finish `enrichmentMargin` earlier so the answer still lands in time.
/// Tests shorten both and widen the margin through `current`, a task local
/// that refreshes started inside `withValue` carry along.
struct AgentUsageTiming: Sendable {
    var refreshDeadline: Duration = .seconds(15)
    var enrichmentMargin: Duration = .seconds(1)

    @TaskLocal static var current = AgentUsageTiming()

    /// When optional enrichment started now must give up.
    var enrichmentDeadline: ContinuousClock.Instant {
        ContinuousClock.now.advanced(by: refreshDeadline - enrichmentMargin)
    }

    var refreshDeadlineSeconds: Int {
        Int(refreshDeadline.components.seconds)
    }
}
