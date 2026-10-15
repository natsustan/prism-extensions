import Foundation

/// Turns the `GET /api/oauth/usage` payload into the launcher's metrics.
///
/// Current accounts list every meter in the `limits` array, classified by
/// `kind`: `session` (5h), `weekly_all`, and `weekly_scoped` entries naming
/// their model. Older payloads carry the same windows as flat
/// `{ utilization, resets_at }` objects (`five_hour`, `seven_day`,
/// `seven_day_<model>`), which remain the fallback. Codenamed keys the server
/// adds for unreleased features are ignored.
enum ClaudeUsageMapper {
    static let sessionWindowSeconds = 18_000
    static let weeklyWindowSeconds = 604_800

    /// Flat per-model weekly windows, in display order.
    static let scopedWeeklyKeys: [(key: String, name: String)] = [
        ("seven_day_opus", "Opus"),
        ("seven_day_sonnet", "Sonnet"),
        ("seven_day_overage_included", "Fable 5"),
        ("seven_day_oauth_apps", "OAuth Apps"),
        ("seven_day_cowork", "Cowork"),
    ]

    /// `organization_type` values from `/api/oauth/profile`, mapped to the
    /// credential record's `subscriptionType` vocabulary as Claude Code does.
    static let organizationSubscriptionTypes: [String: String] = [
        "claude_max": "max",
        "claude_pro": "pro",
        "claude_enterprise": "enterprise",
        "claude_team": "team",
    ]

    static func report(
        from usageData: Data,
        profile profileData: Data?,
        credentials: ClaudeCredentials,
        fetchedAt: Date
    ) throws -> AgentUsageReport {
        guard let root = AgentUsageParse.jsonObject(usageData) else {
            throw AgentUsageClientError.invalidResponse
        }
        let limits = (root["limits"] as? [[String: Any]]) ?? []

        var metrics: [AgentUsageMetric] = []
        if let session = limitMetric(
            limits.first { kind(of: $0) == "session" }, id: "session", title: "5h Limit",
            section: .limits, windowSeconds: sessionWindowSeconds)
            ?? windowMetric(
                root["five_hour"], id: "session", title: "5h Limit", section: .limits,
                windowSeconds: sessionWindowSeconds) {
            metrics.append(session)
        }
        if let weekly = limitMetric(
            limits.first { kind(of: $0) == "weekly_all" }, id: "weekly", title: "Weekly Limit",
            section: .limits, windowSeconds: weeklyWindowSeconds)
            ?? windowMetric(
                root["seven_day"], id: "weekly", title: "Weekly Limit", section: .limits,
                windowSeconds: weeklyWindowSeconds) {
            metrics.append(weekly)
        }
        metrics += scopedWeeklyMetrics(root)
        // An error envelope or a reshaped payload has no quota rows; failing
        // keeps the last good report on screen as stale instead of blanking it.
        guard !metrics.isEmpty else { throw AgentUsageClientError.invalidResponse }
        if let extraUsage = extraUsageMetric(root["extra_usage"]) {
            metrics.append(extraUsage)
        }

        let profile = profileData.flatMap(AgentUsageParse.jsonObject)
        let organization = profile?["organization"] as? [String: Any]
        let profileSubscription = AgentUsageParse.string(organization?["organization_type"])
            .flatMap { organizationSubscriptionTypes[$0.lowercased()] }
        // The profile reflects plan changes the cached credential record can
        // miss; each field falls back to the credential on its own.
        let plan = profileSubscription.map {
            planName(
                subscriptionType: $0,
                rateLimitTier: AgentUsageParse.string(organization?["rate_limit_tier"])
                    ?? credentials.rateLimitTier)
        } ?? planName(
            subscriptionType: credentials.subscriptionType,
            rateLimitTier: credentials.rateLimitTier)

        return AgentUsageReport(
            providerID: .claude,
            providerName: "Claude",
            plan: plan,
            accountLabel: profile.flatMap(email(fromProfile:)),
            metrics: metrics,
            fetchedAt: fetchedAt
        )
    }

    // MARK: - Windows

    static func windowMetric(
        _ value: Any?,
        id: String,
        title: String,
        section: AgentUsageMetric.Section,
        windowSeconds: Int?
    ) -> AgentUsageMetric? {
        guard let window = value as? [String: Any],
              let utilization = AgentUsageParse.number(window["utilization"])
        else { return nil }
        return AgentUsageMetric(
            id: id,
            title: title,
            section: section,
            value: .progress(
                used: AgentUsageParse.clampPercent(utilization),
                limit: 100,
                format: .percent,
                resetsAt: AgentUsageISO8601.date(from: window["resets_at"] as? String),
                windowSeconds: windowSeconds
            )
        )
    }

    /// A `limits` entry: `{ kind, group, percent, resets_at, scope }`.
    static func limitMetric(
        _ entry: [String: Any]?,
        id: String,
        title: String,
        section: AgentUsageMetric.Section,
        windowSeconds: Int?
    ) -> AgentUsageMetric? {
        guard let entry, let percent = AgentUsageParse.number(entry["percent"]) else { return nil }
        return AgentUsageMetric(
            id: id,
            title: title,
            section: section,
            value: .progress(
                used: AgentUsageParse.clampPercent(percent),
                limit: 100,
                format: .percent,
                resetsAt: AgentUsageISO8601.date(from: entry["resets_at"] as? String),
                windowSeconds: windowSeconds
            )
        )
    }

    /// Per-model weekly windows from both shapes, one row per model: the
    /// `limits` entry wins because it carries the server's current model name.
    static func scopedWeeklyMetrics(_ root: [String: Any]) -> [AgentUsageMetric] {
        var metrics: [AgentUsageMetric] = []
        var seenNames: Set<String> = []

        for entry in (root["limits"] as? [[String: Any]]) ?? [] {
            guard kind(of: entry) == "weekly_scoped",
                  let scope = entry["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let name = AgentUsageParse.string(model["display_name"]),
                  !seenNames.contains(weeklyModelIdentity(name)),
                  let metric = limitMetric(
                      entry, id: "weekly-\(slug(name))", title: "\(name) Weekly",
                      section: .perModel, windowSeconds: weeklyWindowSeconds)
            else { continue }
            seenNames.insert(weeklyModelIdentity(name))
            metrics.append(metric)
        }

        for (key, name) in scopedWeeklyKeys where !seenNames.contains(weeklyModelIdentity(name)) {
            if let metric = windowMetric(
                root[key], id: "weekly-\(slug(name))", title: "\(name) Weekly",
                section: .perModel, windowSeconds: weeklyWindowSeconds) {
                seenNames.insert(weeklyModelIdentity(name))
                metrics.append(metric)
            }
        }
        return metrics
    }

    /// The legacy overage-included window is labelled Fable 5; generic
    /// limits may use the shorter Fable name for the same quota.
    private static func weeklyModelIdentity(_ name: String) -> String {
        let normalized = name.lowercased()
        return normalized == "fable 5" ? "fable" : normalized
    }

    // MARK: - Extra usage

    /// Pay-as-you-go spend past the plan limits. Amounts arrive in minor units
    /// (`decimal_places`, cents by default). Only US dollars render as a meter,
    /// because the shared currency format is dollar-denominated.
    static func extraUsageMetric(_ value: Any?) -> AgentUsageMetric? {
        guard let extra = value as? [String: Any],
              let isEnabled = AgentUsageParse.bool(extra["is_enabled"])
        else { return nil }
        guard isEnabled else {
            return AgentUsageMetric(
                id: "extra-usage", title: "Extra Usage", section: .creditsAndResets, value: .badge("Off"))
        }

        let decimalPlaces = AgentUsageParse.number(extra["decimal_places"]).map { min(max($0, 0), 6) } ?? 2
        let scale = pow(10, decimalPlaces)
        let used = (AgentUsageParse.number(extra["used_credits"]) ?? 0) / scale
        let limit = AgentUsageParse.number(extra["monthly_limit"]).map { $0 / scale }
        let currency = AgentUsageParse.string(extra["currency"])?.uppercased() ?? "USD"

        if currency == "USD" {
            if let limit, limit > 0 {
                return AgentUsageMetric(
                    id: "extra-usage",
                    title: "Extra Usage",
                    section: .creditsAndResets,
                    value: .progress(
                        used: used, limit: limit, format: .currency, resetsAt: nil, windowSeconds: nil)
                )
            }
            return AgentUsageMetric(
                id: "extra-usage",
                title: "Extra Usage",
                section: .creditsAndResets,
                value: .text(String(format: "$%.2f used", used))
            )
        }
        let limitText = limit.map { String(format: " of %.2f", $0) } ?? ""
        return AgentUsageMetric(
            id: "extra-usage",
            title: "Extra Usage",
            section: .creditsAndResets,
            value: .text(String(format: "%.2f", used) + limitText + " \(currency)")
        )
    }

    // MARK: - Account

    /// "Max 20x" from `subscriptionType: "max"` and a tier such as
    /// `default_claude_max_20x`; other plans use their capitalized name.
    static func planName(subscriptionType: String?, rateLimitTier: String?) -> String? {
        guard let raw = subscriptionType?.trimmedCredentialValue.lowercased(), !raw.isEmpty else {
            return nil
        }
        let name = raw.replacingOccurrences(of: "_", with: " ").capitalized
        guard raw == "max",
              let tier = rateLimitTier?.lowercased(),
              let multiplier = tier.split(separator: "_").last,
              multiplier.hasSuffix("x"),
              Int(multiplier.dropLast()) != nil
        else { return name }
        return "\(name) \(multiplier)"
    }

    static func email(fromProfile root: [String: Any]) -> String? {
        let account = root["account"] as? [String: Any]
        return AgentUsageParse.string(account?["email"])
            ?? AgentUsageParse.string(account?["email_address"])
    }

    /// Rows are classified by the server's `kind`, never by their label.
    private static func kind(of entry: [String: Any]) -> String? {
        (entry["kind"] as? String)?.lowercased()
    }

    private static func slug(_ value: String) -> String {
        value.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
    }
}
