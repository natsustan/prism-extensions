import Foundation

/// What a run of the 1Password CLI (`op`) gave back.
struct CLIOutput: Equatable, Sendable {
    var status: Int32
    var stdout: Data
    var stderr: String

    init(status: Int32 = 0, stdout: Data = Data(), stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Runs `op`, the 1Password CLI. Behind a protocol so tests answer with
/// canned output instead of a real vault.
protocol OnePasswordCLI: Sendable {
    /// `op` with `arguments`, or nil when no `op` was found. Throws
    /// `CancellationError` when cancelled and `CLITimeout` when it ran past
    /// `timeout`; either way `op` is stopped first.
    func run(_ arguments: [String], executable: String, timeout: Duration) async throws -> CLIOutput?
}

struct CLITimeout: Error, Equatable {}

/// The installed `op`. Prism starts extensions with a short `PATH`, so the
/// folders 1Password's installer and Homebrew use are checked too.
struct InstalledOnePasswordCLI: OnePasswordCLI {
    func run(_ arguments: [String], executable: String, timeout: Duration) async throws -> CLIOutput? {
        guard let url = Self.find(executable) else { return nil }
        let process = CLIProcess(executableURL: url, arguments: arguments)
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: CLIOutput.self) { group in
                group.addTask { try await process.run() }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw CLITimeout()
                }
                defer {
                    process.stop()
                    group.cancelAll()
                }
                guard let output = try await group.next() else { throw CancellationError() }
                return output
            }
        } onCancel: {
            process.stop()
        }
    }

    /// The `op` the user named, or the first one found in `PATH` and the
    /// usual install folders.
    static func find(_ executable: String) -> URL? {
        let manager = FileManager.default
        let named = (executable as NSString).expandingTildeInPath
        if !named.isEmpty {
            return manager.isExecutableFile(atPath: named) ? URL(fileURLWithPath: named) : nil
        }
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let home = manager.homeDirectoryForCurrentUser.path
        let folders = path + [
            "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "\(home)/.local/bin",
            "\(home)/.local/share/mise/shims", "\(home)/.asdf/shims",
            "\(home)/.nix-profile/bin", "/run/current-system/sw/bin",
        ]
        return folders.lazy
            .map { URL(fileURLWithPath: $0).appending(path: "op") }
            .first { manager.isExecutableFile(atPath: $0.path) }
    }
}

/// One run of `op`. Both pipes are drained while it runs, since an item list
/// can be far larger than a pipe's buffer, and stopping it terminates `op` so
/// none outlives the request that started it.
///
/// `op` is started as its own responsible process. To learn whether the
/// desktop app integration is on, it reads 1Password's group container,
/// which macOS guards per responsible app: started plainly, the read is
/// charged to Prism, refused without a prompt, and `op` reports “No accounts
/// configured”. As its own responsible process, `op` reads it as 1Password's
/// own team, as it does from a terminal.
final class CLIProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let executable: String
    private let arguments: [String]
    private var pid: pid_t = 0
    private var isStopped = false

    init(executableURL: URL, arguments: [String]) {
        executable = executableURL.path
        self.arguments = arguments
    }

    func run() async throws -> CLIOutput {
        var output: [Int32] = [-1, -1]
        var errors: [Int32] = [-1, -1]
        guard pipe(&output) == 0 else { return CLIOutput(status: -1, stderr: "Could not start op.") }
        guard pipe(&errors) == 0 else {
            output.forEach { close($0) }
            return CLIOutput(status: -1, stderr: "Could not start op.")
        }
        let spawned: Int32? = lock.withLock {
            guard !isStopped else { return nil }
            return Self.spawn(executable, arguments, stdout: output[1], stderr: errors[1], pid: &pid)
        }
        // The child holds its own copies of the write ends.
        close(output[1])
        close(errors[1])
        let stdoutHandle = FileHandle(fileDescriptor: output[0], closeOnDealloc: true)
        let stderrHandle = FileHandle(fileDescriptor: errors[0], closeOnDealloc: true)
        guard let spawned else { throw CancellationError() }
        guard spawned == 0 else {
            return CLIOutput(status: -1, stderr: "Could not start op: \(String(cString: strerror(spawned))).")
        }
        RunningCLIProcesses.add(self)
        defer { RunningCLIProcesses.remove(self) }
        // Read from launch on, so `op` never blocks on a full pipe.
        async let stdout = Self.drain(stdoutHandle)
        async let stderr = Self.drain(stderrHandle)
        let status = await reap()
        let (out, err) = await (stdout, stderr)
        guard !stoppedNow else { throw CancellationError() }
        return CLIOutput(status: status, stdout: out, stderr: String(decoding: err, as: UTF8.self))
    }

    func stop() {
        lock.withLock {
            isStopped = true
            if pid > 0 { kill(pid, SIGTERM) }
        }
    }

    private var stoppedNow: Bool {
        lock.withLock { isStopped }
    }

    private typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    /// `responsibility_spawnattrs_setdisclaim`, which terminals and
    /// debuggers use for the same reason. Looked up at run time, so a macOS
    /// without it still runs `op`, as Prism's child.
    private static let disclaim: Disclaim? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim")
        .map { unsafeBitCast($0, to: Disclaim.self) }

    private static func spawn(_ executable: String, _ arguments: [String], stdout: Int32, stderr: Int32, pid: inout pid_t) -> Int32 {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the three descriptors below reach `op`; never the protocol's pipes.
        // Signals start at their defaults and unblocked, as Foundation's
        // Process starts a child, so stopping `op` reaches it.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        var noSignals = sigset_t()
        var allSignals = sigset_t()
        sigemptyset(&noSignals)
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        _ = disclaim?(&attributes, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderr, STDERR_FILENO)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        return posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
    }

    /// Waits for `op` to exit, then reaps it with `pid` cleared under the
    /// lock, so `stop` never signals a PID that may already name another
    /// process.
    private func reap() async -> Int32 {
        let pid = lock.withLock { self.pid }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var info = siginfo_t()
                while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
                var status: Int32 = 0
                self.lock.withLock {
                    self.pid = 0
                    while waitpid(pid, &status, 0) == -1, errno == EINTR {}
                }
                // Exited normally: its code; ended by a signal: 128 + signal, as shells report.
                let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                continuation.resume(returning: code)
            }
        }
    }

    private static func drain(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }
}

/// Every `op` still running, stopped when the extension exits normally, as
/// it does when Prism closes its input mid-request, such as while Sign In
/// waits for 1Password's approval. A signal from Prism ends `op` with the
/// rest of the process group instead.
enum RunningCLIProcesses {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var processes: [ObjectIdentifier: CLIProcess] = [:]
    private static let exitHook: Void = {
        atexit { RunningCLIProcesses.stopAll() }
    }()

    static func add(_ process: CLIProcess) {
        _ = exitHook
        lock.withLock { processes[ObjectIdentifier(process)] = process }
    }

    static func remove(_ process: CLIProcess) {
        lock.withLock { processes[ObjectIdentifier(process)] = nil }
    }

    static func stopAll() {
        let running = lock.withLock { Array(processes.values) }
        running.forEach { $0.stop() }
    }
}
