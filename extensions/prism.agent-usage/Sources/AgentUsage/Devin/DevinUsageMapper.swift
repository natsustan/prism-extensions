import Foundation

enum DevinUsageError: Error, Equatable, Sendable {
    case invalidResponse
    /// The request succeeded but carried no quota fields at all.
    case quotaUnavailable
}

/// Turns `GetUserStatus` into metrics. Devin reports quota as percent
/// *remaining*; Prism meters show percent *used*, so every row flips
/// `100 - remaining`. Window lengths are the plan's own cadence: daily and
/// weekly.
enum DevinUsageMapper {
    static let dailyWindowSeconds = 86_400
    static let weeklyWindowSeconds = 604_800

    static func report(from body: Data, fetchedAt: Date) throws -> AgentUsageReport {
        guard let root = AgentUsageParse.jsonObject(body),
              let userStatus = root["userStatus"] as? [String: Any]
        else { throw DevinUsageError.invalidResponse }

        let planStatus = userStatus["planStatus"] as? [String: Any] ?? [:]
        let planInfo = planStatus["planInfo"] as? [String: Any] ?? [:]
        let plan = AgentUsageParse.string(planInfo["planName"])
        let hideDailyQuota = AgentUsageParse.bool(planInfo["hideDailyQuota"]) == true

        let dailyRemaining = AgentUsageParse.number(planStatus["dailyQuotaRemainingPercent"])
        let weeklyRemaining = AgentUsageParse.number(planStatus["weeklyQuotaRemainingPercent"])
        // A present-but-unparsable percentage is schema drift, not an omitted
        // zero: fail loudly instead of reporting a credible "fully used".
        if planStatus["weeklyQuotaRemainingPercent"] != nil, weeklyRemaining == nil {
            throw DevinUsageError.invalidResponse
        }
        if planStatus["dailyQuotaRemainingPercent"] != nil, dailyRemaining == nil {
            throw DevinUsageError.invalidResponse
        }
        let dailyReset = hideDailyQuota ? nil : unixDate(planStatus["dailyQuotaResetAtUnix"])
        let weeklyReset = unixDate(planStatus["weeklyQuotaResetAtUnix"])
        let extraBalance = dollarsFromMicros(planStatus["overageBalanceMicros"])

        var metrics: [AgentUsageMetric] = []
        // Proto3 omits zero values; a reset timestamp still identifies an
        // exhausted daily window even when its percentage is absent.
        if !hideDailyQuota,
           let daily = dailyRemaining ?? (dailyReset != nil ? 0 : nil) {
            metrics.append(quotaMetric(
                id: "daily", title: "Daily Quota",
                remaining: daily, resetsAt: dailyReset,
                windowSeconds: dailyWindowSeconds))
        }

        // Proto3 JSON omits zero values, so a weekly reset with no percentage
        // means an exhausted weekly window, not a missing one.
        if let weekly = weeklyRemaining ?? (weeklyReset != nil ? 0 : nil) {
            metrics.append(quotaMetric(
                id: "weekly", title: "Weekly Quota",
                remaining: weekly, resetsAt: weeklyReset,
                windowSeconds: weeklyWindowSeconds))
        } else if hideDailyQuota, let dailyRemaining {
            // No weekly fields at all: surface the hidden daily quota so the
            // report stays meaningful — still flipped to "used".
            metrics.append(quotaMetric(
                id: "weekly", title: "Weekly Quota",
                remaining: dailyRemaining, resetsAt: weeklyReset,
                windowSeconds: weeklyWindowSeconds))
        }

        if let extraBalance {
            metrics.append(AgentUsageMetric(
                id: "extra-balance",
                title: "Extra Usage Balance",
                section: .creditsAndResets,
                value: .text(String(format: "$%.2f", extraBalance))))
        }

        guard !metrics.isEmpty else { throw DevinUsageError.quotaUnavailable }
        return AgentUsageReport(
            providerID: .devin,
            providerName: "Devin",
            plan: plan,
            accountLabel: nil,
            metrics: metrics,
            fetchedAt: fetchedAt
        )
    }

    private static func quotaMetric(
        id: String,
        title: String,
        remaining: Double,
        resetsAt: Date?,
        windowSeconds: Int
    ) -> AgentUsageMetric {
        AgentUsageMetric(
            id: id,
            title: title,
            section: .limits,
            value: .progress(
                used: AgentUsageParse.clampPercent(100 - remaining),
                limit: 100,
                format: .percent,
                resetsAt: resetsAt,
                windowSeconds: windowSeconds))
    }

    private static func unixDate(_ value: Any?) -> Date? {
        guard let seconds = AgentUsageParse.number(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// `overageBalanceMicros` is millionths of a dollar; a present zero is a
    /// real measured zero, not missing data.
    private static func dollarsFromMicros(_ value: Any?) -> Double? {
        guard let micros = AgentUsageParse.number(value) else { return nil }
        return max(0, micros) / 1_000_000
    }
}
