import Foundation
import PrismExtensionKit

/// One model's quota as any Cloud Code endpoint reports it, normalized before
/// pooling. `remainingFraction` is 0…1 (1 = full); a model with no quota info
/// is treated as depleted.
struct AntigravityModelQuota: Equatable, Sendable {
    var label: String
    var modelID: String?
    var remainingFraction: Double
    var resetTime: Date?
    /// False when the LS endpoint omitted `remainingFraction` and the mapper
    /// substituted 0 — such entries must never supplement a partial summary.
    var hasExplicitFraction: Bool = true
}

/// Turns Antigravity's quota responses into metrics. The authoritative source
/// is `retrieveUserQuotaSummary` (`quotaSummaryMetrics`): two pools — Gemini
/// ("Session"/"Weekly") and every non-Gemini model ("Claude"/"Claude Weekly") —
/// each with a rolling 5-hour and a weekly window. Builds without that RPC fall
/// back to the legacy per-model endpoints, whose quotas collapse into the two
/// 5-hour pool meters keeping each pool's worst remaining fraction.
enum AntigravityUsageMapper {
    /// Internal/duplicate model IDs that must never surface as a meter.
    static let modelBlacklist: Set<String> = [
        "MODEL_CHAT_20706", "MODEL_CHAT_23310",
        "MODEL_GOOGLE_GEMINI_2_5_FLASH", "MODEL_GOOGLE_GEMINI_2_5_FLASH_THINKING",
        "MODEL_GOOGLE_GEMINI_2_5_FLASH_LITE", "MODEL_GOOGLE_GEMINI_2_5_PRO",
        "MODEL_PLACEHOLDER_M19", "MODEL_PLACEHOLDER_M9", "MODEL_PLACEHOLDER_M12",
    ]

    static let sessionWindowSeconds = 18_000
    static let weeklyWindowSeconds = 604_800

    enum Pool {
        /// The shared Gemini pool's rolling 5-hour and weekly windows.
        case session, weekly
        /// The shared non-Gemini pool (Claude, GPT-OSS, …).
        case claude, claudeWeekly

        var id: String {
            switch self {
            case .session: "session"
            case .weekly: "weekly"
            case .claude: "claude"
            case .claudeWeekly: "claude-weekly"
            }
        }

        var title: String {
            switch self {
            case .session: localized("Session")
            case .weekly: localized("Weekly")
            case .claude: "Claude"
            case .claudeWeekly: localized("Claude Weekly")
            }
        }

        var windowSeconds: Int {
            switch self {
            case .session, .claude: sessionWindowSeconds
            case .weekly, .claudeWeekly: weeklyWindowSeconds
            }
        }
    }

    /// The four pool buckets `retrieveUserQuotaSummary` reports, matched by
    /// exact `bucketId` only — a future bucket must never silently join a pool.
    static let summaryBuckets: [(bucketID: String, pool: Pool)] = [
        ("gemini-5h", .session),
        ("gemini-weekly", .weekly),
        ("3p-5h", .claude),
        ("3p-weekly", .claudeWeekly),
    ]

    // MARK: - Quota summary (authoritative)

    /// `retrieveUserQuotaSummary` → up to four pool meters. `nil` means "not a
    /// summary" and the caller may fall back; a non-nil result — even an empty
    /// one — is authoritative: the legacy path fabricates "fully used" from
    /// missing quota info, so a parsed summary must never fall through to it.
    /// A bucket without a usable `remainingFraction` drops its own line rather
    /// than fabricating 0% or 100%.
    static func quotaSummaryMetrics(_ data: Data) -> [AgentUsageMetric]? {
        guard let root = AgentUsageParse.jsonObject(data) else { return nil }
        // The envelope arrives as {"response": …}, {"summary": …}, or bare —
        // the LS RPC uses "response", the Cloud Code endpoint may use either.
        let container = (root["response"] as? [String: Any])
            ?? (root["summary"] as? [String: Any])
            ?? root
        guard let groups = container["groups"] as? [[String: Any]] else { return nil }

        var pooled: [String: (fraction: Double, resetTime: Date?)] = [:]
        for bucket in groups.flatMap({ ($0["buckets"] as? [[String: Any]]) ?? [] }) {
            guard let id = bucket["bucketId"] as? String,
                  summaryBuckets.contains(where: { $0.bucketID == id }),
                  pooled[id] == nil // duplicate bucket id — first one wins
            else { continue }
            guard let fraction = AgentUsageParse.number(bucket["remainingFraction"]), fraction.isFinite
            else { continue }
            pooled[id] = (fraction, AgentUsageISO8601.date(fromAny: bucket["resetTime"]))
        }

        return summaryBuckets.compactMap { spec in
            guard let entry = pooled[spec.bucketID] else { return nil }
            return metric(pool: spec.pool, fraction: entry.fraction, resetTime: entry.resetTime)
        }
    }

    // MARK: - Language-server endpoints

    /// LS `GetUserStatus` → plan name + account email + model quotas. Nil when
    /// the body has no `userStatus`. Google's own `userTier` wins over the
    /// Windsurf-inherited `planInfo.planName` (which reads "Pro" for every
    /// paid tier); `planInfo`'s display-name fields are the next fallback.
    static func userStatus(_ data: Data) -> (plan: String?, email: String?, quotas: [AntigravityModelQuota])? {
        guard let root = AgentUsageParse.jsonObject(data),
              let status = root["userStatus"] as? [String: Any]
        else { return nil }
        let tierName = AgentUsageParse.string((status["userTier"] as? [String: Any])?["name"])
        let planInfo = (status["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any]
        let planName = ["planDisplayName", "displayName", "productName", "planName", "planShortName"]
            .lazy.compactMap { AgentUsageParse.string(planInfo?[$0]) }.first
        let configs = ((status["cascadeModelConfigData"] as? [String: Any])?["clientModelConfigs"]
            as? [[String: Any]]) ?? []
        return (
            formatPlan(tierName ?? planName),
            AgentUsageParse.string(status["email"]),
            configs.compactMap(quota(fromLS:)))
    }

    // MARK: - Cloud Code endpoints (the `agy` credential's own API)

    /// `loadCodeAssist` → plan name: the paid tier wins over the current tier,
    /// matching how the CLI itself labels the account.
    static func cloudPlan(_ data: Data) -> String? {
        guard let root = AgentUsageParse.jsonObject(data) else { return nil }
        let paid = AgentUsageParse.string((root["paidTier"] as? [String: Any])?["name"])
        let current = AgentUsageParse.string((root["currentTier"] as? [String: Any])?["name"])
        return formatPlan(paid ?? current)
    }

    /// `userinfo` → the signed-in account's email.
    static func userInfoEmail(_ data: Data) -> String? {
        AgentUsageParse.string(AgentUsageParse.jsonObject(data)?["email"])
    }

    /// Cloud Code `fetchAvailableModels` → per-model quotas that carry an
    /// explicit finite `remainingFraction`. Internal autocomplete models
    /// (`tab_*`) and unnamed non-chat models are ignored so they never pollute
    /// either pool.
    static func availableModels(_ data: Data) -> [AntigravityModelQuota]? {
        guard let root = AgentUsageParse.jsonObject(data),
              let models = root["models"] as? [String: Any]
        else { return nil }
        var quotas: [AntigravityModelQuota] = []
        for modelID in models.keys.sorted() {
            let lowerID = modelID.lowercased()
            if lowerID.hasPrefix("tab_") || modelBlacklist.contains(modelID) { continue }
            guard let model = models[modelID] as? [String: Any],
                  let quota = model["quotaInfo"] as? [String: Any],
                  let fraction = AgentUsageParse.number(quota["remainingFraction"]),
                  fraction.isFinite
            else { continue }
            let displayName = AgentUsageParse.string(model["displayName"])
            let label: String
            if let displayName {
                label = displayName
            } else if lowerID.contains("gemini") || lowerID.contains("claude") || lowerID.contains("gpt") {
                label = modelID
            } else {
                continue
            }
            quotas.append(AntigravityModelQuota(
                label: label,
                modelID: modelID,
                remainingFraction: fraction,
                resetTime: AgentUsageISO8601.date(fromAny: quota["resetTime"]),
                hasExplicitFraction: true))
        }
        return quotas
    }

    /// Combines authoritative `retrieveUserQuotaSummary` metrics with 5-hour
    /// pool metrics from `fetchAvailableModels` / `GetUserStatus` when the
    /// summary omits a pool (e.g. Cloud Code returning only `3p-*` buckets and
    /// omitting `gemini-5h`), preserving the canonical pool order.
    static func mergeSummaryMetrics(
        _ summary: [AgentUsageMetric],
        fallback: [AgentUsageMetric]
    ) -> [AgentUsageMetric] {
        guard !fallback.isEmpty else { return summary }
        var byID: [String: AgentUsageMetric] = [:]
        for metric in summary { byID[metric.id] = metric }
        for metric in fallback where byID[metric.id] == nil { byID[metric.id] = metric }
        return summaryBuckets.compactMap { byID[$0.pool.id] }
    }

    /// LS `GetCommandModelConfigs` fallback → model quotas only (no plan).
    static func commandModelConfigs(_ data: Data) -> [AntigravityModelQuota]? {
        guard let root = AgentUsageParse.jsonObject(data),
              let configs = root["clientModelConfigs"] as? [[String: Any]]
        else { return nil }
        return configs.compactMap(quota(fromLS:))
    }

    private static func quota(fromLS model: [String: Any]) -> AntigravityModelQuota? {
        guard let label = AgentUsageParse.string(model["label"]) else { return nil }
        let quota = model["quotaInfo"] as? [String: Any]
        let explicitFraction = AgentUsageParse.number(quota?["remainingFraction"])
            .flatMap { $0.isFinite ? $0 : nil }
        return AntigravityModelQuota(
            label: label,
            modelID: AgentUsageParse.string((model["modelOrAlias"] as? [String: Any])?["model"]),
            remainingFraction: explicitFraction ?? 0,
            resetTime: AgentUsageISO8601.date(fromAny: quota?["resetTime"]),
            hasExplicitFraction: explicitFraction != nil)
    }

    // MARK: - Pooling

    /// Collapse per-model quotas into the two 5-hour pool meters, keeping the
    /// worst fraction per pool and ordering the Gemini pool ("Session") first.
    /// The legacy endpoints only know the 5-hour windows.
    static func pooledMetrics(_ quotas: [AntigravityModelQuota]) -> [AgentUsageMetric] {
        var pooled: [Pool: (fraction: Double, resetTime: Date?)] = [:]
        for quota in quotas {
            let label = quota.label.trimmedCredentialValue
            guard !label.isEmpty else { continue }
            if let id = quota.modelID, modelBlacklist.contains(id) { continue }

            let pool: Pool = pool(for: label)
            if let existing = pooled[pool] {
                // Worst-case wins; ties keep the first seen.
                if quota.remainingFraction < existing.fraction {
                    pooled[pool] = (quota.remainingFraction, quota.resetTime)
                }
            } else {
                pooled[pool] = (quota.remainingFraction, quota.resetTime)
            }
        }
        return [Pool.session, .claude].compactMap { pool in
            guard let entry = pooled[pool] else { return nil }
            return metric(pool: pool, fraction: entry.fraction, resetTime: entry.resetTime)
        }
    }

    static func metric(pool: Pool, fraction: Double, resetTime: Date?) -> AgentUsageMetric {
        let clamped = min(max(fraction, 0), 1)
        return AgentUsageMetric(
            id: pool.id,
            title: pool.title,
            section: .limits,
            value: .progress(
                // Whole percents keep a fresh window at 0 so "not started" reads
                // the same as the provider's own client.
                used: ((1 - clamped) * 100).rounded(),
                limit: 100,
                format: .percent,
                resetsAt: resetTime,
                windowSeconds: pool.windowSeconds))
    }

    /// "Gemini 3 Pro (High)" → the Gemini pool; every other model shares the
    /// Claude pool since the 2026-05 quota merge.
    static func pool(for label: String) -> Pool {
        let normalized = label
            .replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
            .trimmedCredentialValue
        return normalized.lowercased().contains("gemini") ? .session : .claude
    }

    /// "Google AI Pro" → "Pro"; "Gemini Code Assist in Google One AI Pro" →
    /// "Pro"; anything else title-cased.
    static func formatPlan(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmedCredentialValue.nilIfEmpty else { return nil }
        if let range = trimmed.range(of: "Google AI "), range.lowerBound == trimmed.startIndex {
            return String(trimmed[range.upperBound...]).capitalized
        }
        for keyword in ["Ultra", "Pro", "Free"] where trimmed.lowercased().contains(keyword.lowercased()) {
            return keyword
        }
        return trimmed.capitalized
    }
}
