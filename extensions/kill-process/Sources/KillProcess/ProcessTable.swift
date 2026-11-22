import Darwin
import Foundation

/// The kernel's process table, read with `sysctl` and `libproc`.
enum ProcessTable {
    /// Every live process in the kernel table (`KERN_PROC_ALL`), skipping PID 0
    /// and zombies. Leaves `path` nil because the snapshot resolves paths from
    /// `ps` and only asks `proc_pidpath` when `comm` is not already a full path.
    static func allKernelProcesses() -> [pid_t: KernelProcessInfo] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        let stride = MemoryLayout<kinfo_proc>.stride

        for _ in 0..<3 {
            var byteSize = 0
            guard sysctl(&mib, 3, nil, &byteSize, nil, 0) == 0, byteSize > 0 else { return [:] }
            // Leave headroom for processes spawned between sizing and reading.
            let capacity = max(1, (byteSize / stride) * 5 / 4 + 16)
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            var actualSize = capacity * stride
            guard sysctl(&mib, 3, &buffer, &actualSize, nil, 0) == 0 else {
                if errno == ENOMEM { continue }
                return [:]
            }
            let count = actualSize / stride
            var result: [pid_t: KernelProcessInfo] = [:]
            result.reserveCapacity(count)

            for info in buffer.prefix(count) {
                let pid = info.kp_proc.p_pid
                guard pid > 0, info.kp_proc.p_stat != SZOMB else { continue }
                result[pid] = KernelProcessInfo(
                    identity: identity(pid, info),
                    parentPID: info.kp_eproc.e_ppid,
                    userID: info.kp_eproc.e_ucred.cr_uid,
                    shortName: withUnsafeBytes(of: info.kp_proc.p_comm) { string($0) },
                    path: nil
                )
            }
            return result
        }
        return [:]
    }

    static func process(_ pid: pid_t) -> KernelProcessInfo? {
        guard pid > 0, let info = kinfo(pid), info.kp_proc.p_stat != SZOMB else { return nil }
        return KernelProcessInfo(
            identity: identity(pid, info),
            parentPID: info.kp_eproc.e_ppid,
            userID: info.kp_eproc.e_ucred.cr_uid,
            shortName: withUnsafeBytes(of: info.kp_proc.p_comm) { string($0) },
            path: path(pid)
        )
    }

    /// The identity of a live process; nil once it has exited or turned zombie.
    static func identity(_ pid: pid_t) -> ProcessIdentity? {
        guard pid > 0, let info = kinfo(pid), info.kp_proc.p_stat != SZOMB else { return nil }
        return identity(pid, info)
    }

    private static func identity(_ pid: pid_t, _ info: kinfo_proc) -> ProcessIdentity {
        let start = info.kp_proc.p_un.__p_starttime
        return ProcessIdentity(pid: pid, startSeconds: Int(start.tv_sec), startMicroseconds: Int(start.tv_usec))
    }

    static func send(_ signal: Int32, to process: ProcessIdentity) throws(SignalError) {
        guard identity(process.pid) == process else { throw .gone }
        guard kill(process.pid, signal) == 0 else {
            switch errno {
            case ESRCH: throw .gone
            case EPERM: throw .notPermitted
            case let code: throw .failed(code)
            }
        }
    }

    static func path(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let resolved = string(buffer)
        return resolved.isEmpty ? nil : resolved
    }

    private static func kinfo(_ pid: pid_t) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    private static func string(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    private static func string(_ bytes: UnsafeRawBufferPointer) -> String {
        String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}
