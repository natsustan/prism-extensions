import Foundation

enum AmpUsageError: Error, Equatable, Sendable {
    /// The API answered `ok: false` with an auth rejection.
    case authRejected
    /// The API answered `ok: false` for another reason; carries its message.
    case requestFailed(String)
    /// A 2xx/`ok` body whose `displayText` is missing or unrecognizable.
    case invalidResponse
}

/// Turns the `userDisplayBalanceInfo` reply into provider-agnostic metrics.
/// The endpoint returns a pre-rendered `displayText` — the same block
/// `amp usage` prints — so parsing is line-oriented text matching over the
/// documented shapes (Amp Free dollars or percent, subscription percentages,
/// tier dollars, individual credits, workspace balances).
enum AmpUsageMapper {
    private static let amount = #"([0-9][0-9,]*(?:\.[0-9]+)?)"#
    private static let windowSecondsPerDay = 86_400
    private static let dailyFreeLimit = 5.0

    static func report(from body: Data, fetchedAt: Date) throws -> AgentUsageReport {
        struct Response: Decodable {
            struct Result: Decodable { let displayText: String? }
            struct Failure: Decodable { let code: String?; let message: String? }
            let ok: Bool
            let result: Result?
            let error: Failure?
        }
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: body)
        } catch {
            throw AmpUsageError.invalidResponse
        }
        guard response.ok else {
            if response.error?.code == "auth-required" { throw AmpUsageError.authRejected }
            throw AmpUsageError.requestFailed(response.error?.message ?? "unknown error")
        }
        guard let text = response.result?.displayText, !text.isEmpty else {
            throw AmpUsageError.invalidResponse
        }
        return try report(fromDisplayText: text, fetchedAt: fetchedAt)
    }

    static func report(fromDisplayText displayText: String, fetchedAt: Date) throws -> AgentUsageReport {
        // The CLI wraps labels in `**` markdown since 0.0.1787…; strip it.
        let text = displayText.replacingOccurrences(of: "**", with: "")

        var metrics: [AgentUsageMetric] = []
        var plan: String?

        if let free = parseFreeTier(text, now: fetchedAt) {
            metrics.append(free)
            plan = plan ?? "Free"
        }
        if let subscription = parseSubscription(text, now: fetchedAt) {
            metrics += subscription.metrics
            plan = subscription.plan
        }
        if let credits = firstMatch(
            in: text, pattern: #"^\s*Individual credits:\s*\$?"# + amount + #"\s+remaining"#),
           let balance = number(credits[0])
        {
            metrics.append(AgentUsageMetric(
                id: "credits",
                title: "Credits",
                section: .creditsAndResets,
                value: .text(dollarText(balance))))
        }
        // Newer replies fold the daily free balance into the credits line:
        // "Individual credits: $19.01 remaining (includes $4.98 Amp Free
        // remaining today; resets daily)". Amp Free has a $5 daily allowance.
        if !metrics.contains(where: { $0.id == "free" }),
           let free = firstMatch(
               in: text,
               pattern: #"\bincludes\s+\$?"# + amount + #"\s+Amp\s+Free\s+remaining\s+today"#),
           let remaining = number(free[0])
        {
            metrics.insert(AgentUsageMetric(
                id: "free",
                title: "Amp Free",
                section: .limits,
                value: .progress(
                    used: dailyFreeLimit - min(max(remaining, 0), dailyFreeLimit),
                    limit: dailyFreeLimit, format: .currency,
                    resetsAt: nil, windowSeconds: windowSecondsPerDay)), at: 0)
        }
        var workspaceCounts: [String: Int] = [:]
        for workspace in allMatches(
            in: text, pattern: #"^\s*Workspace\s+(.+?):\s*\$?"# + amount + #"\s+remaining"#)
        where workspace.count == 2 {
            guard let name = workspace[0].trimmedCredentialValue.nilIfEmpty,
                  let balance = number(workspace[1]) else { continue }
            let occurrence = workspaceCounts[name, default: 0]
            workspaceCounts[name] = occurrence + 1
            metrics.append(AgentUsageMetric(
                id: "workspace-\(name)-\(occurrence)",
                title: "Workspace \(name)",
                section: .creditsAndResets,
                value: .text(dollarText(balance))))
        }

        guard !metrics.isEmpty else { throw AmpUsageError.invalidResponse }
        return AgentUsageReport(
            providerID: .amp,
            providerName: "Amp",
            plan: plan ?? "Credits",
            accountLabel: accountLabel(from: text),
            metrics: metrics,
            fetchedAt: fetchedAt
        )
    }

    // MARK: - Line parsing

    /// "Amp Free: $4.20/$10 remaining (replenishes +$0.42/hour)" or the newer
    /// percent form "Amp Free: 42% remaining today (resets daily)".
    private static func parseFreeTier(_ text: String, now: Date) -> AgentUsageMetric? {
        if let captures = firstMatch(
            in: text,
            pattern: #"^\s*Amp Free:\s*\$?"# + amount + #"\s*/\s*\$?"# + amount
                + #"\s+remaining(?:\s*\(replenishes\s*\+\$?"# + amount + #"\s*/\s*hour\))?"#),
           let remaining = number(captures[0]),
           let total = number(captures[1]), total > 0
        {
            let used = max(0, total - remaining)
            let rate = captures.count > 2 ? number(captures[2]) : nil
            // Amp Free refills continuously; the reset is when it would be full again.
            let resetsAt: Date? = if let rate, used > 0, rate > 0 {
                now.addingTimeInterval(used / rate * 3_600)
            } else {
                nil
            }
            return AgentUsageMetric(
                id: "free",
                title: "Amp Free",
                section: .limits,
                value: .progress(
                    used: used / total * 100, limit: 100, format: .percent,
                    resetsAt: resetsAt, windowSeconds: windowSecondsPerDay))
        }
        if let captures = firstMatch(
            in: text,
            pattern: #"^\s*Amp Free:\s*"# + amount + #"\s*%\s+remaining(?:\s+today)?"#),
           let remaining = number(captures[0])
        {
            return AgentUsageMetric(
                id: "free",
                title: "Amp Free",
                section: .limits,
                value: .progress(
                    used: 100 - min(max(remaining, 0), 100), limit: 100, format: .percent,
                    resetsAt: nil, windowSeconds: windowSecondsPerDay))
        }
        return nil
    }

    private struct Subscription {
        var plan: String?
        var metrics: [AgentUsageMetric]
    }

    /// "Amp <Plan> Subscription: 32% other usage and 97% orb usage remaining -
    /// resets upon renewal in 5 days" — or the newer "Amp <Plan> Tier: agent
    /// usage $R of $L remaining (…orb usage Xh of Yh…) resets upon renewal in N
    /// days".
    private static func parseSubscription(_ text: String, now: Date) -> Subscription? {
        let suffix = #"\s*"# + amount + #"\s*%\s+other\s+usage\s+and\s+"# + amount
            + #"\s*%\s+orb\s+usage\s+remaining\s*-\s*resets\s+upon\s+renewal\s+in\s+"#
            + #"([0-9][0-9,]*)\s+(days?|months?)"#
        for pattern in [
            #"^\s*Subscription\s+(.+?):"# + suffix,
            #"^\s*Amp\s+(.+?)\s+Subscription:"# + suffix,
        ] {
            guard let captures = firstMatch(in: text, pattern: pattern), captures.count == 5,
                  let otherRemaining = number(captures[1]),
                  let orbRemaining = number(captures[2]),
                  let renewal = number(captures[3])
            else { continue }
            let resetsAt = renewalDate(value: renewal, unit: captures[4], now: now)
            let plan = captures[0].trimmedCredentialValue.nilIfEmpty
            return Subscription(plan: plan, metrics: [
                AgentUsageMetric(
                    id: "subscription",
                    title: "\(plan ?? "Subscription") Usage",
                    section: .limits,
                    value: .progress(
                        used: 100 - min(max(otherRemaining, 0), 100), limit: 100, format: .percent,
                        resetsAt: resetsAt, windowSeconds: windowSeconds(resetsAt: resetsAt, now: now))),
                AgentUsageMetric(
                    id: "orb-usage",
                    title: "Orb Usage",
                    section: .perModel,
                    value: .progress(
                        used: 100 - min(max(orbRemaining, 0), 100), limit: 100, format: .percent,
                        resetsAt: resetsAt, windowSeconds: windowSeconds(resetsAt: resetsAt, now: now))),
            ])
        }

        let tierPattern = #"^\s*Amp\s+([^\r\n]+?)\s+Tier:\s*agent\s+usage\s+\$"# + amount
            + #"\s+of\s+\$"# + amount
            + #"\s+remaining\b([^\r\n]*?)resets\s+upon\s+renewal\s+in\s+"#
            + #"([0-9][0-9,]*)\s+(days?|months?)\b"#
        if let captures = firstMatch(in: text, pattern: tierPattern), captures.count == 6,
           let plan = captures[0].trimmedCredentialValue.nilIfEmpty,
           let remaining = number(captures[1]),
           let limit = number(captures[2]), limit > 0,
           let renewal = number(captures[4])
        {
            let resetsAt = renewalDate(value: renewal, unit: captures[5], now: now)
            var metrics = [AgentUsageMetric(
                id: "subscription",
                title: "\(plan) Usage",
                section: .limits,
                value: .progress(
                    used: (limit - max(remaining, 0)) / limit * 100, limit: 100, format: .percent,
                    resetsAt: resetsAt, windowSeconds: windowSeconds(resetsAt: resetsAt, now: now)))]
            // The tier line's parenthetical carries orb hours: "orb usage 12h of
            // 100h a1.small orb hours remaining".
            if let orb = firstMatch(
                in: captures[3],
                pattern: #"\borb\s+usage\s+"# + amount + #"h\s+of\s+"# + amount
                    + #"h\s+a1\.small\s+orb\s+hours\s+remaining"#),
               let orbRemaining = number(orb[0]),
               let orbLimit = number(orb[1]), orbLimit > 0
            {
                metrics.append(AgentUsageMetric(
                    id: "orb-usage",
                    title: "Orb Usage",
                    section: .perModel,
                    value: .progress(
                        used: (orbLimit - max(orbRemaining, 0)) / orbLimit * 100,
                        limit: 100, format: .percent,
                        resetsAt: resetsAt, windowSeconds: windowSeconds(resetsAt: resetsAt, now: now))))
            }
            return Subscription(plan: plan, metrics: metrics)
        }
        return nil
    }

    private static func accountLabel(from text: String) -> String? {
        guard let captures = firstMatch(
            in: text, pattern: #"^\s*Signed in as\s+([^\s(]+)(?:\s+\(([^\r\n)]+)\))?\s*$"#)
        else { return nil }
        return [captures[0], captures.count > 1 ? captures[1] : nil]
            .compactMap { $0?.trimmedCredentialValue.nilIfEmpty }
            .joined(separator: " · ")
            .trimmedCredentialValue.nilIfEmpty
    }

    // MARK: - Regex helpers

    private static func firstMatch(in text: String, pattern: String) -> [String]? {
        allMatches(in: text, pattern: pattern).first
    }

    /// All matches of a multiline-anchored pattern, each as its capture group
    /// strings (`""` for groups that did not participate).
    private static func allMatches(in text: String, pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.anchorsMatchLines, .caseInsensitive])
        else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).map { match in
            (1..<match.numberOfRanges).map { index in
                let group = match.range(at: index)
                guard group.location != NSNotFound, let range = Range(group, in: text) else { return "" }
                return String(text[range])
            }
        }
    }

    private static func number(_ raw: String) -> Double? {
        Double(raw.replacingOccurrences(of: ",", with: ""))
    }

    private static func dollarText(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    private static func renewalDate(value: Double, unit: String, now: Date) -> Date? {
        let days = unit.lowercased().hasPrefix("month") ? 31 : 1
        let interval = value * Double(days * windowSecondsPerDay)
        guard interval > 0 else { return nil }
        return now.addingTimeInterval(interval)
    }

    private static func windowSeconds(resetsAt: Date?, now: Date) -> Int? {
        guard let resetsAt else { return nil }
        return Int(exactly: resetsAt.timeIntervalSince(now).rounded())
    }
}
