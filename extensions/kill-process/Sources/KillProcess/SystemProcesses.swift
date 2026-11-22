import Darwin
import Foundation

/// The Mac itself: `/bin/ps` for live CPU and memory usage, `sysctl`/`libproc`
/// for process identities, and `/usr/bin/open` for relaunch and Finder.
struct SystemProcesses: ProcessSystem {
    static let psExecutable = URL(fileURLWithPath: "/bin/ps")
    static let psArguments = ["-axo", "pid=,ppid=,uid=,stat=,pcpu=,rss=,comm="]
    static let psTimeout: Duration = .seconds(3)

    var currentUserID: uid_t { getuid() }
    var currentPID: pid_t { getpid() }

    func snapshot() async throws -> [ProcessRecord] {
        let data = try await CommandRunner.output(
            of: Self.psExecutable,
            arguments: Self.psArguments,
            environment: ["LC_ALL": "C"],
            timeout: Self.psTimeout
        )
        let rows = ProcessSnapshotParser.parse(String(decoding: data, as: UTF8.self))
        let kernel = ProcessTable.allKernelProcesses()
        let selfPID = currentPID

        var records: [ProcessRecord] = []
        records.reserveCapacity(rows.count)
        for row in rows where row.pid != selfPID && row.parentPID != selfPID {
            guard let info = kernel[row.pid] ?? ProcessTable.process(row.pid) else { continue }
            let resolvedPath: String?
            if row.comm.hasPrefix("/") {
                resolvedPath = row.comm
            } else {
                resolvedPath = info.path ?? ProcessTable.path(row.pid)
            }
            records.append(ProcessRecord(
                identity: info.identity,
                parentPID: info.parentPID,
                userID: info.userID,
                shortName: info.shortName,
                path: resolvedPath,
                comm: row.comm,
                cpu: row.cpu,
                memoryBytes: row.memoryBytes
            ))
        }
        return records
    }

    func process(_ pid: pid_t) -> KernelProcessInfo? {
        ProcessTable.process(pid)
    }

    func send(_ signal: Int32, to process: ProcessIdentity) throws(SignalError) {
        try ProcessTable.send(signal, to: process)
    }

    func isRunning(_ process: ProcessIdentity) -> Bool {
        ProcessTable.identity(process.pid) == process
    }

    func fileExists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func open(_ path: String) async throws {
        _ = try await CommandRunner.output(
            of: URL(fileURLWithPath: "/usr/bin/open"),
            arguments: [path],
            timeout: .seconds(5)
        )
    }

    func reveal(_ path: String) async throws {
        _ = try await CommandRunner.output(
            of: URL(fileURLWithPath: "/usr/bin/open"),
            arguments: ["-R", path],
            timeout: .seconds(5)
        )
    }

    func bundleIdentifier(ofAppAt path: String) -> String? {
        Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier
    }
}
