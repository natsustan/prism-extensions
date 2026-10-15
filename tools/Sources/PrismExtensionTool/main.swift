import Darwin
import Foundation
import PrismExtensionProtocol

/// `prism-extension lint <folder>...` checks folders the way Prism and the
/// Gallery do; `prism-extension smoke <folder>...` runs each extension once
/// over the protocol. CI runs both on every extension a change touches.
let usage = """
Usage:
  prism-extension lint <folder>...    check manifest, executable, and repository rules
  prism-extension smoke <folder>...   start the extension, run a protocol round trip, and stop it
"""

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, ["lint", "smoke"].contains(command), arguments.count > 1 else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}

var failed = false
for path in arguments.dropFirst() {
    let folder = URL(fileURLWithPath: path).standardizedFileURL
    do {
        switch command {
        case "lint": try Lint.check(folder)
        default: try Smoke.run(folder)
        }
        print("✓ \(command) \(path)")
    } catch {
        failed = true
        print("✗ \(command) \(path): \(error)")
    }
}
exit(failed ? 1 : 0)

struct ToolFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Whether a folder is a first-party extension in this repository, which may
/// use the reserved `prism.` namespace.
func isFirstParty(_ folder: URL) -> Bool {
    folder.deletingLastPathComponent().lastPathComponent == "extensions"
        && folder.lastPathComponent.hasPrefix("prism.")
}

func manifest(of folder: URL) throws -> ExtensionManifest {
    do {
        return try ExtensionFolderValidator.manifest(in: folder, allowsReservedNamespace: isFirstParty(folder))
    } catch let failure as ExtensionFolderValidator.Failure {
        throw ToolFailure(failure.message)
    }
}

// MARK: - Lint

enum Lint {
    static func check(_ folder: URL) throws {
        let manifest = try manifest(of: folder)
        // Gallery entries live in extensions/<id>/ with a README and a changelog.
        guard folder.deletingLastPathComponent().lastPathComponent == "extensions" else { return }
        guard folder.lastPathComponent == manifest.id.rawValue else {
            throw ToolFailure("The folder must be named after the extension ID, \(manifest.id.rawValue).")
        }
        for file in ["README.md", "CHANGELOG.md"] where !FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(file).path
        ) {
            throw ToolFailure("\(file) is missing.")
        }
        if manifest.summary?.isEmpty ?? true {
            throw ToolFailure("The manifest needs a one-sentence “description” for the Gallery.")
        }
    }
}

// MARK: - Smoke

/// Starts the extension in its own process group, sends `initialize`, loads
/// each list command and widget once (read-only requests; commands with side
/// effects are not run), closes stdin, and expects the whole group gone.
enum Smoke {
    static let replyTimeout: TimeInterval = 5
    static let exitTimeout: TimeInterval = 3

    static func run(_ folder: URL) throws {
        let manifest = try manifest(of: folder)
        let executable = try ExtensionFolderValidator.executableURL(of: manifest, in: folder)
        let process = try SpawnedExtension(executable: executable, directory: folder)
        defer { process.killGroup() }

        var nextID = 1
        func call<Params: Encodable>(_ method: String, _ params: Params) throws {
            let id = nextID
            nextID += 1
            try process.send(ExtensionMessage.request(id: id, method: method, params: params))
            let reply = try process.reply(to: id, timeout: replyTimeout)
            if let error = reply.error {
                throw ToolFailure("\(method) failed: \(error.message)")
            }
        }

        try call(ExtensionMethod.initialize, ExtensionInitializeParams(
            prismVersion: "smoke", extensionID: manifest.id, preferences: [:], state: [:]
        ))
        for command in manifest.commands where command.mode == .list {
            try call(ExtensionMethod.listLoad, ExtensionListParams(commandID: command.id))
        }
        for widget in manifest.widgets {
            try call(ExtensionMethod.widgetLoad, ExtensionWidgetParams(widgetID: widget.id))
        }

        process.closeInput()
        guard process.waitForExit(timeout: exitTimeout) else {
            throw ToolFailure("The extension did not exit within \(Int(exitTimeout)) s of stdin closing.")
        }
        guard !process.groupIsAlive() else {
            throw ToolFailure("The extension left processes running after it exited.")
        }
    }
}

/// One extension process: stdin and stdout pipes, stderr passed through, and
/// its own process group so leftovers can be found and ended.
final class SpawnedExtension {
    let pid: pid_t
    private let input: Int32
    private let output: Int32
    private var lines = ExtensionLineBuffer()
    private var pending: [ExtensionMessage] = []
    private var exited = false

    init(executable: URL, directory: URL) throws {
        var stdinPipe: [Int32] = [0, 0]
        var stdoutPipe: [Int32] = [0, 0]
        guard pipe(&stdinPipe) == 0, pipe(&stdoutPipe) == 0 else {
            throw ToolFailure("Could not create pipes: \(String(cString: strerror(errno)))")
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
        for fd in stdinPipe + stdoutPipe { posix_spawn_file_actions_addclose(&actions, fd) }
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        var pid: pid_t = 0
        let path = executable.path
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { argv.forEach { free($0) } }
        let status = posix_spawn(&pid, path, &actions, &attributes, argv, environ)
        close(stdinPipe[0])
        close(stdoutPipe[1])
        guard status == 0 else {
            close(stdinPipe[1])
            close(stdoutPipe[0])
            throw ToolFailure("Could not start \(path): \(String(cString: strerror(status)))")
        }
        self.pid = pid
        input = stdinPipe[1]
        output = stdoutPipe[0]
        signal(SIGPIPE, SIG_IGN)
    }

    deinit {
        close(input)
        close(output)
    }

    func send(_ message: ExtensionMessage) throws {
        let data = try message.line()
        let written = data.withUnsafeBytes { write(input, $0.baseAddress, $0.count) }
        guard written == data.count else {
            throw ToolFailure("The extension stopped reading stdin.")
        }
    }

    /// The response to request `id`; notifications and logs in between are skipped.
    func reply(to id: Int, timeout: TimeInterval) throws -> ExtensionMessage {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let index = pending.firstIndex(where: { $0.kind == .response(id: id) }) {
                return pending.remove(at: index)
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw ToolFailure("No reply to request \(id) within \(Int(timeout)) s.")
            }
            var poller = pollfd(fd: output, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, Int32(remaining * 1000)) > 0 else { continue }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = read(output, &buffer, buffer.count)
            guard count > 0 else {
                throw ToolFailure("The extension closed stdout before replying to request \(id).")
            }
            for line in try lines.append(Data(buffer.prefix(count))) {
                do {
                    pending.append(try ExtensionWire.decode(ExtensionMessage.self, from: line))
                } catch {
                    throw ToolFailure("stdout carried a line that is not a protocol message: \(String(decoding: line, as: UTF8.self))")
                }
            }
        }
    }

    func closeInput() {
        close(input)
    }

    func waitForExit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid {
                exited = true
                return true
            }
            usleep(20_000)
        }
        return false
    }

    func groupIsAlive() -> Bool {
        kill(-pid, 0) == 0
    }

    /// Ends whatever is left of the group; safe to call more than once.
    func killGroup() {
        kill(-pid, SIGKILL)
        if !exited {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            exited = true
        }
    }
}
