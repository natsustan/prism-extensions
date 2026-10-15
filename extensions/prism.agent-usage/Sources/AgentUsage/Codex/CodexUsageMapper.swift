import Foundation

/// Decoded `GET /backend-api/wham/usage` body. Only the fields Prism renders.
struct CodexUsageResponse: Decodable, Equatable {
    struct Window: Decodable, Equatable {
        let usedPercent: Double?
        let limitWindowSeconds: Int?
        let resetAfterSeconds: Double?
        let resetAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAfterSeconds = "reset_after_seconds"
            case resetAt = "reset_at"
        }
    }

    struct Limit: Decodable, Equatable {
        let primaryWindow: Window?
        let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct AdditionalLimit: Decodable, Equatable {
        let limitName: String?
        let meteredFeature: String?
        let rateLimit: Limit?

        enum CodingKeys: String, CodingKey {
            case limitName = "limit_name"
            case meteredFeature = "metered_feature"
            case rateLimit = "rate_limit"
        }
    }

    struct Credits: Decodable, Equatable {
        let hasCredits: Bool?
        let unlimited: Bool?
        /// Numbers and numeric strings both appear in the wild; anything else
        /// decodes to nil instead of failing the whole response.
        let balance: LenientDouble?

        enum CodingKeys: String, CodingKey {
            case hasCredits = "has_credits"
            case unlimited
            case balance
        }
    }

    struct ResetCredits: Decodable, Equatable {
        let availableCount: Double?
        let credits: [Credit]?

        struct Credit: Decodable, Equatable {
            let status: String?
            let expiresAt: String?

            enum CodingKeys: String, CodingKey {
                case status
                case expiresAt = "expires_at"
            }
        }

        enum CodingKeys: String, CodingKey {
            case availableCount = "available_count"
            case credits
        }
    }

    let planType: String?
    let email: String?
    let rateLimit: Limit?
    let codeReviewRateLimit: Limit?
    let additionalRateLimits: [AdditionalLimit]?
    let credits: Credits?
    let rateLimitResetCredits: ResetCredits?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case email
        case rateLimit = "rate_limit"
        case codeReviewRateLimit = "code_review_rate_limit"
        case additionalRateLimits = "additional_rate_limits"
        case credits
        case rateLimitResetCredits = "rate_limit_reset_credits"
    }
}

/// A JSON value that may arrive as a number or a numeric string. Decoding never
/// throws: a value Prism cannot read is treated as absent.
struct LenientDouble: Decodable, Equatable, Sendable {
    let value: Double?

    init(_ value: Double?) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
        } else if let string = try? container.decode(String.self), let number = Double(string) {
            value = number
        } else {
            value = nil
        }
    }
}

/// Turns the Codex payload into the launcher's provider-agnostic metrics.
enum CodexUsageMapper {
    /// ChatGPT credits are priced at 4¢ each, matching what the Codex CLI shows
    /// for the same balance.
    static let creditUSDRate = 0.04

    /// The window length Codex uses for its 5-hour session limit.
    static let sessionWindowSeconds = 18_000
    /// The window length Codex uses for the weekly limit.
    static let weeklyWindowSeconds = 604_800

    enum WindowSlot: Equatable {
        case primary
        case secondary
    }

    enum WindowKind: Equatable {
        case session
        case weekly
        case other(seconds: Int)

        var title: String {
            switch self {
            case .session: "5h Limit"
            case .weekly: "Weekly Limit"
            case let .other(seconds): "\(AgentUsageFormat.durationText(TimeInterval(seconds))) Limit"
            }
        }
    }

    /// Windows are classified by their declared length rather than their
    /// primary/secondary slot: an account can report only a weekly window
    /// (as this Mac's does), and slots have moved between plans before.
    static func windowKind(seconds: Int?, slot: WindowSlot) -> WindowKind {
        switch seconds {
        case .some(sessionWindowSeconds): return .session
        case .some(weeklyWindowSeconds): return .weekly
        case let .some(other): return .other(seconds: other)
        case nil: return slot == .primary ? .session : .weekly
        }
    }

    static func planName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmedCredentialValue, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "prolite": return "Pro 5x"
        case "pro": return "Pro 20x"
        case "self_serve_business_prolite": return "Business Premium"
        case "plus": return "Plus"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        case "edu": return "Edu"
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// "796 · $31.84": the floored credit count plus its dollar value at the
    /// Codex CLI's 4¢ per credit. An exhausted balance reads as a plain zero.
    static func creditText(balance: Double) -> String {
        guard let wholeCredits = Int(exactly: balance.rounded(.down)) else { return "—" }
        let credits = max(0, wholeCredits)
        guard credits > 0 else { return "0" }
        return "\(credits) · \(String(format: "$%.2f", Double(credits) * creditUSDRate))"
    }

    static func report(
        from usageData: Data,
        resetCredits resetCreditsData: Data?,
        credentials: CodexCredentials,
        fetchedAt: Date
    ) throws -> AgentUsageReport {
        let response: CodexUsageResponse
        do {
            response = try JSONDecoder().decode(CodexUsageResponse.self, from: usageData)
        } catch {
            throw AgentUsageClientError.invalidResponse
        }

        // Numeric strings can decode to infinity, and finite doubles can still
        // exceed Int's range. Reject malformed primary counts before formatting.
        for value in [response.credits?.balance?.value, response.rateLimitResetCredits?.availableCount] {
            if let value, Int(exactly: value.rounded(.down)) == nil {
                throw AgentUsageClientError.invalidResponse
            }
        }

        var metrics = windowMetrics(
            from: response.rateLimit, idPrefix: "", titlePrefix: nil, section: .limits, now: fetchedAt)
        metrics += windowMetrics(
            from: response.codeReviewRateLimit,
            idPrefix: "code-review-",
            titlePrefix: "Code Review",
            section: .limits,
            now: fetchedAt
        )
        for limit in response.additionalRateLimits ?? [] {
            let name = limit.limitName ?? limit.meteredFeature ?? "Additional Limit"
            metrics += windowMetrics(
                from: limit.rateLimit,
                idPrefix: "limit-\(slug(name))-",
                titlePrefix: name,
                section: .perModel,
                now: fetchedAt
            )
        }
        if let credits = creditsMetric(response.credits) {
            metrics.append(credits)
        }
        metrics += resetCreditsMetrics(
            body: response.rateLimitResetCredits, dedicated: resetCreditsData, now: fetchedAt)

        // Names can repeat or normalize to the same slug across limits.
        // Allocate identities across the entire report, including window slots.
        var usedIDs: Set<String> = []
        metrics = metrics.map { metric in
            var id = metric.id
            var suffix = 2
            while !usedIDs.insert(id).inserted {
                id = "\(metric.id)-\(suffix)"
                suffix += 1
            }
            return AgentUsageMetric(
                id: id, title: metric.title, section: metric.section, value: metric.value)
        }

        return AgentUsageReport(
            providerID: .codex,
            providerName: "Codex",
            plan: planName(response.planType),
            accountLabel: response.email,
            metrics: metrics,
            fetchedAt: fetchedAt
        )
    }

    // MARK: - Metric building

    static func windowMetrics(
        from limit: CodexUsageResponse.Limit?,
        idPrefix: String,
        titlePrefix: String?,
        section: AgentUsageMetric.Section,
        now: Date
    ) -> [AgentUsageMetric] {
        guard let limit else { return [] }
        let slots: [(CodexUsageResponse.Window?, WindowSlot)] = [
            (limit.primaryWindow, .primary),
            (limit.secondaryWindow, .secondary),
        ]
        var metrics: [AgentUsageMetric] = []
        for (window, slot) in slots {
            guard let window, window.usedPercent != nil else { continue }
            let kind = windowKind(seconds: window.limitWindowSeconds, slot: slot)
            // Ids stay stable and readable even when the title carries a
            // human-formatted duration.
            let slug: String
            switch kind {
            case .session: slug = "session"
            case .weekly: slug = "weekly"
            case let .other(seconds): slug = "window-\(seconds)"
            }
            var id = idPrefix + slug
            // Both slots can report the same window length; keep metric ids unique.
            while metrics.contains(where: { $0.id == id }) { id += "-2" }
            metrics.append(AgentUsageMetric(
                id: id,
                title: titlePrefix.map { metrics.isEmpty ? $0 : "\($0) — \(kind.title)" } ?? kind.title,
                section: section,
                value: .progress(
                    used: window.usedPercent ?? 0,
                    limit: 100,
                    format: .percent,
                    resetsAt: resetDate(for: window, now: now),
                    windowSeconds: window.limitWindowSeconds
                )
            ))
        }
        return metrics
    }

    static func resetDate(for window: CodexUsageResponse.Window, now: Date) -> Date? {
        if let resetAt = window.resetAt, resetAt > 0 {
            return Date(timeIntervalSince1970: resetAt)
        }
        if let resetAfter = window.resetAfterSeconds, resetAfter > 0 {
            return now.addingTimeInterval(resetAfter)
        }
        return nil
    }

    static func creditsMetric(_ credits: CodexUsageResponse.Credits?) -> AgentUsageMetric? {
        guard let credits else { return nil }
        if credits.unlimited == true {
            return AgentUsageMetric(
                id: "credits", title: "Credits", section: .creditsAndResets, value: .badge("Unlimited"))
        }
        let balance = credits.balance?.value
        if let balance, balance > 0 {
            return AgentUsageMetric(
                id: "credits",
                title: "Credits",
                section: .creditsAndResets,
                value: .text(creditText(balance: balance))
            )
        }
        if credits.hasCredits == false || balance != nil {
            return AgentUsageMetric(
                id: "credits", title: "Credits", section: .creditsAndResets, value: .text("0"))
        }
        return nil
    }

    /// Reset credits: the count row plus one dated row per still-available
    /// credit. The dedicated endpoint carries the expiries; the usage body's
    /// embedded object is the count-only fallback when that call failed.
    static func resetCreditsMetrics(
        body: CodexUsageResponse.ResetCredits?,
        dedicated: Data?,
        now: Date
    ) -> [AgentUsageMetric] {
        var availableCount: Double?
        var expiries: [Date] = []
        if let dedicated,
           let parsed = try? JSONDecoder().decode(CodexUsageResponse.ResetCredits.self, from: dedicated),
           let count = parsed.availableCount,
           Int(exactly: count.rounded(.down)) != nil {
            availableCount = count
            expiries = availableExpiries(parsed.credits, now: now)
        }
        if availableCount == nil {
            availableCount = body?.availableCount
            expiries = availableExpiries(body?.credits, now: now)
        }
        guard let availableCount, availableCount > 0,
              let wholeCount = Int(exactly: availableCount.rounded(.down)) else { return [] }

        var metrics = [AgentUsageMetric(
            id: "reset-credits",
            title: "Rate Limit Resets",
            section: .creditsAndResets,
            value: .text("\(wholeCount) available")
        )]
        for (index, expiry) in expiries.enumerated() {
            metrics.append(AgentUsageMetric(
                id: "reset-credit-\(index + 1)",
                title: "Manual Reset \(index + 1) Expires",
                section: .creditsAndResets,
                value: .date(expiry)
            ))
        }
        return metrics
    }

    /// Expiries still in the future, soonest first. A credit with no status
    /// counts as available; only an explicitly spent one is dropped.
    private static func availableExpiries(
        _ credits: [CodexUsageResponse.ResetCredits.Credit]?,
        now: Date
    ) -> [Date] {
        (credits ?? [])
            .compactMap { credit in
                if let status = credit.status?.lowercased(), status != "available" { return nil }
                guard let date = AgentUsageISO8601.date(from: credit.expiresAt), date > now else {
                    return nil
                }
                return date
            }
            .sorted()
    }

    private static func slug(_ value: String) -> String {
        value.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
    }
}
