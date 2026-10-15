import Foundation

/// Tracks pool quota for Antigravity (Google's Codeium/Windsurf-derived IDE and
/// its `agy` CLI). Quotas are fraction-based and shown as up to four percent
/// meters: the shared Gemini pool and the shared non-Gemini pool (Claude,
/// GPT-OSS), each with a rolling 5-hour and a weekly window.
///
/// Sources, best first:
/// 1. Antigravity language server (running desktop app / IDE extension).
/// 2. `agy` language server (running CLI: the bare `agy` binary or the
///    `language_server` it installs under `antigravity-cli`).
/// 3. The `agy` CLI's own OAuth credential file, exchanged for the Cloud Code
///    quota endpoints it calls itself. `agy` builds that gate the loopback API
///    behind a runtime-generated CSRF token make the local path unusable from
///    outside the process, so this fallback is what keeps usage visible then.
///
/// On the language-server sources `RetrieveUserQuotaSummary` is tried first —
/// the only endpoint reporting the merged pools and the weekly windows;
/// builds without it fall back to the legacy per-model endpoints, which are
/// 5-hour only.
struct AntigravityAgentUsageProvider: AgentUsageProvider {
    let id: AgentUsageProviderID = .antigravity
    let displayName = "Antigravity"
    let icon: AgentUsageProviderIcon = .asset("icons/antigravity.svg")

    var usageClient = AntigravityUsageClient()
    var discovery = AntigravityLanguageServerDiscovery()
    var authStore = AntigravityAuthStore()
    /// Install detection seam — tests substitute it so the suite never depends
    /// on what the host actually has installed.
    var installPresence: @Sendable () -> Bool = { AntigravityPresence.isInstalled() }

    /// A matching install or the `agy` credential file — file checks only, no
    /// subprocess, no network, no Keychain.
    func hasLocalCredentials() -> Bool {
        installPresence() || authStore.hasCredentials()
    }

    func fetchUsage() async -> Result<AgentUsageReport, AgentUsageFailure> {
        let optionalDeadline = AgentUsageTiming.current.enrichmentDeadline
        let outcome = await probe()
        guard !Task.isCancelled else { return .failure(.network("Cancelled.")) }
        switch outcome {
        case .result(let result):
            return .success(AgentUsageReport(
                providerID: id,
                providerName: displayName,
                plan: result.plan,
                accountLabel: result.account,
                metrics: result.metrics,
                fetchedAt: Date()))
        case .cancelled:
            return .failure(.network("Cancelled."))
        case .answered, .unreachable, .noProcess:
            break
        }
        // The local API produced nothing — an unsigned-in or CSRF-gated `agy`
        // is indistinguishable from a dead port, so the saved `agy` credential
        // is the fallback that still reaches the same quota service.
        switch await authStore.accessToken() {
        case .token(let accessToken):
            return await cloudUsage(accessToken: accessToken, optionalDeadline: optionalDeadline)
        case .failed(let failure):
            return .failure(failure)
        case .absent:
            return lsFailure(outcome)
        }
    }

    // MARK: - Cloud Code fallback

    /// The `agy` OAuth token's own quota service: `retrieveUserQuotaSummary`
    /// is required (it carries the four pool meters), while `loadCodeAssist`
    /// and `userinfo` only enrich plan/email and may fail without failing the
    /// report.
    private func cloudUsage(
        accessToken: String,
        optionalDeadline: ContinuousClock.Instant
    ) async -> Result<AgentUsageReport, AgentUsageFailure> {
        let quota: AgentUsageHTTPResponse
        do {
            quota = try await usageClient.cloudPost(
                AntigravityUsageClient.quotaSummaryURL, accessToken: accessToken)
        } catch {
            return .failure(.network(
                "Couldn't reach Antigravity's quota service. Check your connection."))
        }
        if quota.statusCode == 401 || quota.statusCode == 403 {
            return .failure(.authExpired(
                "Antigravity rejected the saved `agy` sign-in. Run `agy` to sign in again."))
        }
        guard quota.isSuccess else {
            return .failure(.network("Antigravity Cloud Code API error: HTTP \(quota.statusCode)."))
        }
        guard let metrics = AntigravityUsageMapper.quotaSummaryMetrics(quota.body) else {
            return .failure(.invalidResponse(
                "Antigravity's quota service answered with data Prism couldn't read."))
        }
        guard !Task.isCancelled else { return .failure(.network("Cancelled.")) }
        let planBody = await AgentUsageRequestBudget.optionalData(before: optionalDeadline) {
            let response = try await usageClient.cloudPost(
                AntigravityUsageClient.loadCodeAssistURL, accessToken: accessToken)
            guard response.isSuccess else { throw AgentUsageClientError.http(response.statusCode) }
            return response.body
        }
        let infoBody = await AgentUsageRequestBudget.optionalData(before: optionalDeadline) {
            let response = try await usageClient.cloudGet(
                AntigravityUsageClient.userInfoURL, accessToken: accessToken)
            guard response.isSuccess else { throw AgentUsageClientError.http(response.statusCode) }
            return response.body
        }
        return .success(AgentUsageReport(
            providerID: id,
            providerName: displayName,
            plan: planBody.flatMap(AntigravityUsageMapper.cloudPlan),
            accountLabel: infoBody.flatMap(AntigravityUsageMapper.userInfoEmail),
            metrics: metrics,
            fetchedAt: Date()))
    }

    /// The failure a language-server-only provider would have reported — kept
    /// for hosts without the `agy` credential file.
    private func lsFailure(_ outcome: LSOutcome) -> Result<AgentUsageReport, AgentUsageFailure> {
        switch outcome {
        case .answered:
            return .failure(.invalidResponse(
                "Antigravity's local API answered with data Prism couldn't read."))
        case .unreachable:
            return .failure(.network(
                "Antigravity is running but its local API isn't answering. "
                + "Make sure you're signed in, restart Antigravity or `agy`, and try again."))
        case .noProcess:
            return .failure(.notConfigured(
                "Antigravity isn't running. Open Antigravity or run `agy`, then refresh."))
        case .cancelled:
            return .failure(.network("Cancelled."))
        case .result:
            preconditionFailure("checked by caller")
        }
    }

    private struct ProbeResult {
        var plan: String?
        var account: String? = nil
        var metrics: [AgentUsageMetric]
    }

    /// How a single probe attempt ended — the provider prefers the most
    /// informative failure across both sources.
    private enum LSOutcome {
        case result(ProbeResult)
        /// An endpoint returned HTTP, but nothing parsed into metrics.
        case answered
        /// A process was found, but every endpoint failed at transport level.
        case unreachable
        /// No matching process exists.
        case noProcess
        /// The task was cancelled mid-probe; the result is discarded anyway.
        case cancelled
    }

    /// Desktop app / IDE extension language server — requires its
    /// `--csrf_token`. "gemini.app" is the renamed Antigravity desktop app.
    private static let appOptions = AntigravityLanguageServerDiscovery.Options(
        processName: "language_server",
        markers: [
            "antigravity", "antigravity-ide",
            "antigravity.app", "antigravity ide.app", "gemini.app",
        ],
        csrfFlag: "--csrf_token",
        portFlag: "--extension_server_port")

    /// The `agy` CLI hosts the same server locally — either as the bare `agy`
    /// binary or a language_server under its `antigravity-cli` directory. The
    /// token isn't on the command line, so a stand-in is sent; builds that
    /// enforce a runtime-generated token simply reject it, which surfaces as
    /// "running but unreachable" rather than a credential failure.
    private static let cliOptions = AntigravityLanguageServerDiscovery.Options(
        processName: "agy",
        markers: [],
        executableMarkers: ["antigravity-cli", "antigravity_cli"],
        csrfFlag: "--csrf_token",
        csrfOptional: true,
        portFlag: "--extension_server_port")

    private func probe() async -> LSOutcome {
        let app = await probeLS(options: Self.appOptions)
        if case .cancelled = app { return .cancelled }
        if case .result = app { return app }
        let cli = await probeLS(options: Self.cliOptions)
        if case .cancelled = cli { return .cancelled }
        if case .result = cli { return cli }
        if case .answered = app { return .answered }
        if case .answered = cli { return .answered }
        if case .unreachable = app { return .unreachable }
        if case .unreachable = cli { return .unreachable }
        return .noProcess
    }

    // MARK: - Language server

    /// Blocking subprocess (`ps`/`lsof`) must not stall the cooperative
    /// executor or hold a cancelled refresh open while it finishes.
    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T? {
        let completion = DiscoveryCompletion<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard completion.install(continuation) else { return }
                Task.detached(priority: .utility) {
                    completion.finish(work())
                }
            }
        } onCancel: {
            completion.cancel()
        }
    }

    /// Exactly one of cancellation or discovery resumes the waiting task.
    /// The subprocess may finish later; its result is then discarded.
    private final class DiscoveryCompletion<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        private var cancelled = false

        func install(_ continuation: CheckedContinuation<T?, Never>) -> Bool {
            let shouldRun = lock.withLock {
                guard !cancelled else { return false }
                self.continuation = continuation
                return true
            }
            if !shouldRun { continuation.resume(returning: nil) }
            return shouldRun
        }

        func finish(_ result: T) {
            let pending = lock.withLock {
                let pending = continuation
                continuation = nil
                return pending
            }
            pending?.resume(returning: result)
        }

        func cancel() {
            let pending = lock.withLock {
                cancelled = true
                let pending = continuation
                continuation = nil
                return pending
            }
            pending?.resume(returning: nil)
        }
    }

    private func probeLS(
        options: AntigravityLanguageServerDiscovery.Options
    ) async -> LSOutcome {
        guard !Task.isCancelled else { return .cancelled }
        let discovery = self.discovery
        let discoveryResult = await Self.offMain { discovery.discover(options) }
        guard !Task.isCancelled else { return .cancelled }
        guard let discoveryResult, let discovered = discoveryResult else { return .noProcess }

        // HTTPS first (the LS serves a self-signed cert), then HTTP, then the
        // HTTP-only extension port — which may carry its own CSRF token.
        var endpoints: [(scheme: String, port: Int, csrf: String)] = []
        for port in discovered.ports {
            endpoints.append(("https", port, discovered.csrf))
            endpoints.append(("http", port, discovered.csrf))
        }
        if let extensionPort = discovered.extensionPort {
            endpoints.append(("http", extensionPort, discovered.extensionCSRF ?? discovered.csrf))
        }

        var answered = false
        for endpoint in endpoints {
            guard !Task.isCancelled else { return .cancelled }

            // Reachability check: the same process can hold non-API listeners
            // open, so an endpoint only enters the real chain once it answers
            // GetUnleashData — the dedicated context payload is one the real
            // server always recognizes. A rejection (401…) fails every other
            // method the same way and is skipped; a 404 just means this build
            // lacks the method, so the real chain is still worth trying.
            guard let unleash = await usageClient.callLS(
                scheme: endpoint.scheme, port: endpoint.port, csrf: endpoint.csrf,
                method: "GetUnleashData", body: AntigravityUsageClient.lsUnleashBody),
                  unleash.isSuccess || unleash.statusCode == 404
            else { continue }

            // GetUserStatus is the primary source: plan, account, per-model
            // quotas.
            guard !Task.isCancelled else { return .cancelled }
            var parsed: (plan: String?, email: String?, quotas: [AntigravityModelQuota])?
            if let response = await usageClient.callLS(
                scheme: endpoint.scheme, port: endpoint.port,
                csrf: endpoint.csrf, method: "GetUserStatus")
            {
                answered = true
                if response.isSuccess {
                    parsed = AntigravityUsageMapper.userStatus(response.body)
                }
            }

            // The quota summary is authoritative for the merged pools whenever
            // the server produces one — even an empty one: the legacy pooling
            // below fabricates "fully used" from missing quota info, so a
            // parsed summary never falls through to it.
            guard !Task.isCancelled else { return .cancelled }
            let summary = await usageClient.callLS(
                scheme: endpoint.scheme, port: endpoint.port,
                csrf: endpoint.csrf, method: "RetrieveUserQuotaSummary")
            if summary != nil { answered = true }
            if let summary,
               summary.isSuccess,
               let metrics = AntigravityUsageMapper.quotaSummaryMetrics(summary.body)
            {
                return .result(ProbeResult(
                    plan: parsed?.plan, account: parsed?.email, metrics: metrics))
            }

            // No usable summary — pool the per-model quotas GetUserStatus
            // reported (legacy builds are 5-hour only).
            if let parsed {
                let metrics = AntigravityUsageMapper.pooledMetrics(parsed.quotas)
                if !metrics.isEmpty {
                    return .result(ProbeResult(
                        plan: parsed.plan, account: parsed.email, metrics: metrics))
                }
            }

            // GetUserStatus gave nothing — the documented fallback endpoint.
            guard !Task.isCancelled else { return .cancelled }
            if let fallback = await usageClient.callLS(
                scheme: endpoint.scheme, port: endpoint.port,
                csrf: endpoint.csrf, method: "GetCommandModelConfigs")
            {
                answered = true
                if fallback.isSuccess,
                   let quotas = AntigravityUsageMapper.commandModelConfigs(fallback.body)
                {
                    let metrics = AntigravityUsageMapper.pooledMetrics(quotas)
                    if !metrics.isEmpty {
                        return .result(ProbeResult(
                            plan: parsed?.plan, account: parsed?.email, metrics: metrics))
                    }
                }
            }
        }
        guard !Task.isCancelled else { return .cancelled }
        return answered ? .answered : .unreachable
    }
}

/// Cheap "Antigravity exists on this Mac" probe — app data dirs, the `agy` CLI's
/// data dir, the binary, and the app bundle itself. File existence only: no
/// subprocess, no Keychain.
enum AntigravityPresence {
    static func isInstalled(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        let candidates = [
            home.appendingPathComponent(".antigravity").path,
            home.appendingPathComponent(".gemini/antigravity").path,
            home.appendingPathComponent(".gemini/antigravity-cli").path,
            home.appendingPathComponent(".local/bin/agy").path,
            "/usr/local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/Applications/Antigravity.app",
            "/Applications/Gemini.app",
            home.appendingPathComponent("Applications/Antigravity.app").path,
            home.appendingPathComponent("Applications/Gemini.app").path,
        ]
        return candidates.contains(where: fileExists)
    }
}
