import Foundation

enum ZAIUsageError: Error, Equatable, Sendable {
    case invalidResponse
    /// Valid key, but the account has no GLM Coding Plan (the quota endpoint
    /// answers a 2xx with `success: false` and a "coding plan" message).
    case noCodingPlan
}

/// Turns Z.ai's `quota/limit` payload into metrics. The `limits` array mixes
/// window types: a `CREDIT_LIMIT` (legacy `TOKENS_LIMIT`) entry is a percent
/// quota whose `(unit, number)` pair encodes the window — sub-daily is the
/// session meter, multi-day the weekly one — and a `TIME_LIMIT` entry is the
/// monthly web-search count.
enum ZAIUsageMapper {
    /// Web-search rows cycle monthly; the session/weekly meters carry the
    /// payload's own window instead.
    static let monthlyWindowSeconds = 30 * 86_400

    static func report(
        quotaBody: Data,
        subscriptionBody: Data?,
        fetchedAt: Date
    ) throws -> AgentUsageReport {
        AgentUsageReport(
            providerID: .zai,
            providerName: "Z.ai",
            plan: subscriptionBody.flatMap(planName(from:)),
            accountLabel: nil,
            metrics: try mapQuota(quotaBody),
            fetchedAt: fetchedAt
        )
    }

    /// A 2xx quota body can still be the "valid key, no coding plan" signal:
    /// `{"success":false, "msg":"…coding plan"}` with no `data`.
    static func isNoCodingPlan(_ body: Data) -> Bool {
        guard let root = AgentUsageParse.jsonObject(body),
              (root["success"] as? Bool) == false else { return false }
        return ((root["msg"] as? String) ?? "").lowercased().contains("coding plan")
    }

    static func mapQuota(_ body: Data) throws -> [AgentUsageMetric] {
        guard let root = AgentUsageParse.jsonObject(body) else {
            throw ZAIUsageError.invalidResponse
        }
        // `limits` lives under `data`; older payloads expose it at the root.
        let container: [String: Any]
        if let data = root["data"] {
            guard let data = data as? [String: Any] else { throw ZAIUsageError.invalidResponse }
            container = data
        } else {
            container = root
        }
        guard let limits = container["limits"] as? [[String: Any]] else {
            throw ZAIUsageError.invalidResponse
        }
        guard !limits.isEmpty else { return [] }

        var metrics: [AgentUsageMetric] = []

        for entry in limits {
            let type = (entry["type"] as? String) ?? (entry["name"] as? String)
            guard type == "CREDIT_LIMIT" || type == "TOKENS_LIMIT",
                  let window = try classifyWindow(entry)
            else { continue }
            metrics.append(try percentMetric(entry, window: window))
        }
        if let web = limits.first(where: {
            ($0["type"] as? String) == "TIME_LIMIT" || ($0["name"] as? String) == "TIME_LIMIT"
        }) {
            metrics.append(try webSearchMetric(from: web))
        }

        // A non-empty `limits` with nothing renderable is schema drift to flag,
        // not an account with no quotas.
        guard !metrics.isEmpty else { throw ZAIUsageError.invalidResponse }
        return metrics
    }

    /// `productName` of the first subscription entry ("GLM Coding Max").
    static func planName(from body: Data) -> String? {
        guard let root = AgentUsageParse.jsonObject(body),
              let list = root["data"] as? [[String: Any]],
              let first = list.first
        else { return nil }
        return AgentUsageParse.string(first["productName"])
    }

    // MARK: - Private

    private enum TokenWindow {
        case session(seconds: Int)
        case weekly(seconds: Int)

        var title: String {
            switch self {
            case .session: "Session"
            case .weekly: "Weekly"
            }
        }

        var seconds: Int {
            switch self {
            case let .session(seconds), let .weekly(seconds): seconds
            }
        }

        var id: String {
            switch self {
            case .session: "session"
            case .weekly: "weekly"
            }
        }
    }

    /// Z.ai encodes the window as `(unit, number)`: unit 3 is hours, 4 days,
    /// 5 months, 6 weeks. Sub-daily → session; anything longer → weekly.
    /// Unknown units are ignored so a future window cannot hide the known ones.
    private static func classifyWindow(_ entry: [String: Any]) throws -> TokenWindow? {
        guard let unit = AgentUsageParse.number(entry["unit"]),
              let count = AgentUsageParse.number(entry["number"]),
              count > 0 else { throw ZAIUsageError.invalidResponse }
        let unitSeconds: Double
        switch unit {
        case 3: unitSeconds = 3_600
        case 4: unitSeconds = 86_400
        case 5: unitSeconds = 30 * 86_400
        case 6: unitSeconds = 7 * 86_400
        default: return nil
        }
        let duration = unitSeconds * count
        guard duration >= 1, duration < Double(Int.max), let seconds = Int(exactly: duration.rounded()) else {
            throw ZAIUsageError.invalidResponse
        }
        return seconds < 86_400 ? .session(seconds: seconds) : .weekly(seconds: seconds)
    }

    /// `percentage` is the used share; `nextResetTime` is epoch milliseconds.
    private static func percentMetric(
        _ entry: [String: Any],
        window: TokenWindow
    ) throws -> AgentUsageMetric {
        guard let percentage = AgentUsageParse.number(entry["percentage"]) else {
            throw ZAIUsageError.invalidResponse
        }
        return AgentUsageMetric(
            id: window.id,
            title: window.title,
            section: .limits,
            value: .progress(
                used: AgentUsageParse.clampPercent(percentage),
                limit: 100,
                format: .percent,
                resetsAt: epochMilliseconds(entry["nextResetTime"]),
                windowSeconds: window.seconds))
    }

    /// `TIME_LIMIT` → the monthly web-search/reader count meter.
    private static func webSearchMetric(from entry: [String: Any]) throws -> AgentUsageMetric {
        guard let used = AgentUsageParse.number(entry["currentValue"]),
              let limit = AgentUsageParse.number(entry["usage"]),
              used >= 0, limit >= 0
        else { throw ZAIUsageError.invalidResponse }
        let resetsAt = epochMilliseconds(entry["nextResetTime"])
        return AgentUsageMetric(
            id: "web-searches",
            title: "Web Searches",
            section: .limits,
            value: .progress(
                used: used,
                limit: limit,
                format: .count,
                resetsAt: resetsAt,
                windowSeconds: monthlyWindowSeconds))
    }

    private static func epochMilliseconds(_ value: Any?) -> Date? {
        guard let ms = AgentUsageParse.number(value), ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}
