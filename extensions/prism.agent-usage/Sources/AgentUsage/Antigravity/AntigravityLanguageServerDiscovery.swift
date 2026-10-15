import Darwin
import Foundation

/// Outcome of a bounded subprocess call — stdout is all the discovery needs.
struct AntigravityProcessResult: Sendable {
    var exitCode: Int32
    var stdout: String

    var succeeded: Bool { exitCode == 0 }
}

/// The seam `AntigravityLanguageServerDiscovery` shells out through; tests
/// substitute canned `ps`/`lsof` output so no test spawns a real process.
protocol AntigravityProcessRunning: Sendable {
    func run(executable: String, arguments: [String], timeout: TimeInterval) throws
        -> AntigravityProcessResult
}

struct SystemAntigravityProcessRunner: AntigravityProcessRunning {
    enum RunnerError: Error {
        case timedOut
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval) throws
        -> AntigravityProcessResult
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        // Drain stdout on a background queue BEFORE the child runs: `ps -ax`
        // alone exceeds the ~64KB pipe buffer, and a child blocked on write
        // would never exit to trip the timeout below.
        let drained = DispatchGroup()
        let output = OutputBox()
        drained.enter()
        let readHandle = stdoutPipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            output.set(readHandle.readDataToEndOfFile())
            drained.leave()
        }

        let exited = DispatchGroup()
        exited.enter()
        process.terminationHandler = { _ in exited.leave() }

        try process.run()

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            drained.wait()
            throw RunnerError.timedOut
        }

        process.waitUntilExit()
        drained.wait()
        return AntigravityProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: output.data, encoding: .utf8) ?? "")
    }

    /// Lock-guarded box for the drained pipe data.
    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
        func set(_ data: Data) { lock.lock(); storage = data; lock.unlock() }
    }
}

/// Finds a running Codeium-derived language server (Antigravity's bundled
/// `language_server`, or the `agy` CLI) and returns the CSRF token + listening
/// ports needed to call its local Connect-RPC service. All work is blocking
/// subprocess I/O — call `discover` off a hot path (the provider wraps it in a
/// detached task).
struct AntigravityLanguageServerDiscovery: Sendable {
    struct Options: Sendable {
        /// Executable name to match (`language_server`, `agy`).
        var processName: String
        /// Marker values matched against the command: when the process carries
        /// `--app_data_dir` / `--ide_name` / `--override_ide_name`, any marker
        /// appearing anywhere in the command wins; otherwise a `/marker/` path
        /// substring. Empty means "match any instance".
        var markers: [String]
        /// Path components matched against the executable's own path (argv0)
        /// — e.g. `antigravity-cli` matches the `agy`-installed language server
        /// regardless of its flags. Matched independently of `processName`.
        var executableMarkers: [String] = []
        /// Flag whose value is the CSRF token (`--csrf_token`).
        var csrfFlag: String
        /// A CLI-hosted server exposes no `--csrf_token`; rather than skip the
        /// candidate, the "cli-dummy-token" stand-in is sent (accepted by
        /// builds that don't validate it, harmlessly rejected otherwise).
        /// When false, a missing token skips the candidate.
        var csrfOptional: Bool = false
        /// Optional flag carrying an HTTP fallback port
        /// (`--extension_server_port`).
        var portFlag: String?
    }

    struct Result: Sendable {
        var pid: Int32
        var csrf: String
        var ports: [Int]
        var extensionPort: Int?
        /// `--extension_server_csrf_token` — the extension port authenticates
        /// with its own token when the flag is present.
        var extensionCSRF: String?
    }

    var processRunner: any AntigravityProcessRunning = SystemAntigravityProcessRunner()

    func discover(_ options: Options) -> Result? {
        guard let ps = try? processRunner.run(
            executable: "/bin/ps",
            arguments: ["-ax", "-o", "pid=,command="],
            timeout: 5
        ), ps.succeeded else { return nil }

        let candidates = Self.rankedCandidates(psOutput: ps.stdout, options: options)
        guard !candidates.isEmpty else { return nil }

        let lsofPath = ["/usr/sbin/lsof", "/usr/bin/lsof"]
            .first { FileManager.default.fileExists(atPath: $0) }

        for candidate in candidates {
            // The desktop/IDE server requires its real CSRF token; a
            // CLI-hosted candidate exposes none, so it degrades to the
            // stand-in only when declared optional.
            guard let csrf = Self.extractFlag(command: candidate.command, flag: options.csrfFlag)
                ?? (options.csrfOptional ? Self.cliDummyToken : nil)
            else { continue }

            let extensionPort = options.portFlag
                .flatMap { Self.extractFlag(command: candidate.command, flag: $0) }
                .flatMap(Int.init)
            let extensionCSRF = Self.extractFlag(
                command: candidate.command, flag: "--extension_server_csrf_token")

            var ports: [Int] = []
            if let lsofPath, let result = try? processRunner.run(
                executable: lsofPath,
                arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(candidate.pid)],
                timeout: 5
            ), result.succeeded {
                ports = Self.parseListeningPorts(result.stdout)
            }

            if ports.isEmpty && extensionPort == nil { continue }
            return Result(
                pid: candidate.pid, csrf: csrf, ports: ports,
                extensionPort: extensionPort, extensionCSRF: extensionCSRF)
        }
        return nil
    }

    /// Sent as `x-codeium-csrf-token` when a CLI-hosted process exposes no
    /// `--csrf_token`. Builds that skip validation accept any value; builds
    /// that enforce a runtime-generated token reject it and the endpoint then
    /// fails the reachability check like a dead port.
    static let cliDummyToken = "cli-dummy-token"

    // MARK: - Pure helpers (unit-tested directly)

    /// Parse `ps -ax -o pid=,command=` into matching candidates sorted by
    /// marker rank (flag-mention match before path-substring match).
    static func rankedCandidates(
        psOutput: String, options: Options
    ) -> [(pid: Int32, command: String)] {
        let processName = options.processName.lowercased()
        let markers = options.markers
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        let executableMarkers = options.executableMarkers
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }

        var ranked: [(rank: Int, pid: Int32, command: String)] = []
        for rawLine in psOutput.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty,
                  let spaceIndex = line.firstIndex(where: { $0 == " " || $0 == "\t" })
            else { continue }
            let command = String(line[line.index(after: spaceIndex)...])
                .trimmingCharacters(in: .whitespaces)
            guard let pid = Int32(String(line[..<spaceIndex])) else { continue }

            let processMatch = commandMatchesProcess(
                command: command, processNameLower: processName)
            // Executable-path match: the CLI's bundled language server lives
            // under `antigravity-cli` regardless of its argv flags. Match on
            // argv0 only — never on arguments — so a helper spawned inside a
            // CLI working directory (e.g. `git` under `antigravity-cli/scratch`)
            // is not mistaken for the server; and the executable itself must
            // still look like a server, which skips helpers the CLI ships in
            // the same bin directory (`agentapi`, `webm_encoder`, …).
            let executablePath = argv0(command: command).lowercased()
            let executableMatch = executableMarkers.contains {
                executablePath.contains("/\($0)/")
            } && (executablePath as NSString).lastPathComponent.contains("language_server")
            guard processMatch || executableMatch,
                  let rank = markerRank(command: command, markersLower: markers)
            else { continue }
            ranked.append((rank, pid, command))
        }
        return ranked.sorted { $0.rank < $1.rank }.map { ($0.pid, $0.command) }
    }

    /// Extract a CLI flag's value, handling `--flag value` and `--flag=value`.
    static func extractFlag(command: String, flag: String) -> String? {
        let parts = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let flagEq = flag + "="
        for (index, part) in parts.enumerated() {
            if part == flag {
                if index + 1 < parts.count { return parts[index + 1] }
            } else if part.hasPrefix(flagEq) {
                return String(part.dropFirst(flagEq.count))
            }
        }
        return nil
    }

    /// Marker match priority: when the command carries an identity flag
    /// (`--ide_name` / `--override_ide_name` / `--app_data_dir`), any marker
    /// appearing anywhere in the command wins (rank 0 — the flag marks this as
    /// a Codeium-lineage server, and the marker just needs to identify which);
    /// else a `/marker/` path substring (rank 1). Empty markers match any
    /// instance.
    static func markerRank(command: String, markersLower: [String]) -> Int? {
        if markersLower.isEmpty { return 0 }

        let commandLower = command.lowercased()
        let hasIdentityFlag = ["--ide_name", "--override_ide_name", "--app_data_dir"]
            .contains { commandLower.contains($0) }
        if hasIdentityFlag {
            return markersLower.contains { commandLower.contains($0) } ? 0 : nil
        }

        return markersLower.contains { commandLower.contains("/\($0)/") } ? 1 : nil
    }

    /// First argv token, honoring a quoted executable path.
    static func argv0(command: String) -> String {
        let trimmed = command.drop { $0 == " " || $0 == "\t" }
        guard let quote = trimmed.first, quote == "\"" || quote == "'" else {
            return trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        }
        let rest = trimmed.dropFirst()
        if let end = rest.firstIndex(of: quote) { return String(rest[..<end]) }
        return trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
    }

    static func commandMatchesProcess(command: String, processNameLower: String) -> Bool {
        guard !processNameLower.isEmpty else { return false }
        let exeName = (argv0(command: command) as NSString).lastPathComponent.lowercased()
        if exeName == processNameLower { return true }

        let commandLower = command.lowercased()
        if processNameLower.count >= 8 {
            return exeName.hasPrefix("\(processNameLower)_") || commandLower.contains(processNameLower)
        }
        return commandLower.hasSuffix("/\(processNameLower)")
            || commandLower.contains("/\(processNameLower) ")
            || commandLower.contains("/\(processNameLower)\t")
    }

    /// Listening ports from `lsof -nP -iTCP -sTCP:LISTEN` output (deduped).
    static func parseListeningPorts(_ output: String) -> [Int] {
        var ports = Set<Int>()
        for line in output.split(whereSeparator: \.isNewline) where line.contains("LISTEN") {
            for token in line.split(separator: " ").reversed() {
                if let colon = token.lastIndex(of: ":"),
                   let port = Int(token[token.index(after: colon)...]),
                   port > 0, port < 65_536 {
                    ports.insert(port)
                    break
                }
            }
        }
        return ports.sorted()
    }
}
