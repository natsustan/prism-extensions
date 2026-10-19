import Foundation

/// Parses the Grok CLI's credits endpoint and turns it into report rows.
enum GrokUsageMapper {
    /// The shared weekly pool xAI migrated unified-billing accounts to.
    static let weeklyPeriodType = "USAGE_PERIOD_TYPE_WEEKLY"

    /// The slice of the credits config Prism renders.
    struct CreditsConfig: Equatable, Sendable {
        var periodType: String
        /// 0...100 as reported; clamping happens here.
        var usedPercent: Double
        var periodStart: Date
        var periodEnd: Date
        /// Pay-as-you-go cap in credits; 0 when disabled (proto-JSON drops a 0).
        var onDemandCap: Double

        var windowSeconds: Int? { Int(exactly: periodEnd.timeIntervalSince(periodStart).rounded()) }
    }

    /// The response is a proto3 message serialized as JSON, so zero-valued
    /// fields are omitted: an absent `creditUsagePercent` means 0, while a
    /// *present* non-numeric value is schema drift and must fail loudly rather
    /// than be clamped to zero.
    static func decodeCreditsConfig(_ data: Data) throws -> CreditsConfig {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw AgentUsageClientError.invalidResponse
        }
        guard let config = response.config,
              let period = config.currentPeriod,
              let periodType = period.type?.trimmedCredentialValue, !periodType.isEmpty,
              let start = AgentUsageISO8601.date(from: period.start),
              let end = AgentUsageISO8601.date(from: period.end),
              end > start,
              Int(exactly: end.timeIntervalSince(start).rounded()) != nil,
              (config.creditUsagePercent ?? 0).isFinite,
              Int(exactly: (config.onDemandCap?.val ?? 0).rounded(.down)) != nil
        else {
            throw AgentUsageClientError.invalidResponse
        }
        return CreditsConfig(
            periodType: periodType,
            usedPercent: config.creditUsagePercent ?? 0,
            periodStart: start,
            periodEnd: end,
            onDemandCap: config.onDemandCap?.val ?? 0
        )
    }

    /// `subscription_tier_display` from `/v1/settings`; nil when the call failed
    /// or the account has no tier name.
    static func planName(fromSettings data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return (object["subscription_tier_display"] as? String)?.trimmedCredentialValue
    }

    static func report(
        config: CreditsConfig,
        credentials: GrokCredentials,
        plan: String?,
        fetchedAt: Date
    ) -> AgentUsageReport {
        var metrics: [AgentUsageMetric] = []
        if config.periodType == weeklyPeriodType {
            metrics.append(AgentUsageMetric(
                id: "weekly",
                title: "Weekly Limit",
                section: .limits,
                value: .progress(
                    used: min(max(config.usedPercent, 0), 100),
                    limit: 100,
                    format: .percent,
                    resetsAt: config.periodEnd,
                    windowSeconds: config.windowSeconds
                )
            ))
        } else {
            // An account still on the older monthly billing has no shared weekly
            // pool. Reporting its monthly percent as "weekly" would be worse
            // than an honest blank.
            metrics.append(AgentUsageMetric(
                id: "weekly", title: "Weekly Limit", section: .limits, value: .badge("No data")))
        }
        metrics.append(AgentUsageMetric(
            id: "pay-as-you-go",
            title: "Pay as you go",
            section: .creditsAndResets,
            value: .badge(config.onDemandCap > 0 ? "\(formatUnits(config.onDemandCap)) cap" : "Disabled")
        ))
        return AgentUsageReport(
            providerID: .grok,
            providerName: "Grok",
            plan: plan,
            accountLabel: credentials.email,
            metrics: metrics,
            fetchedAt: fetchedAt
        )
    }

    private static func formatUnits(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if let wholeValue = Int(exactly: value) { return String(wholeValue) }
        return String(value)
    }
    private struct Response: Decodable {
        let config: Config?
    }

    private struct Config: Decodable {
        let creditUsagePercent: Double?
        let currentPeriod: Period?
        let onDemandCap: Cap?
    }

    private struct Period: Decodable {
        let type: String?
        let start: String?
        let end: String?
    }

    private struct Cap: Decodable {
        let val: Double?
    }
}
