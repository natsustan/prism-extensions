import Darwin
import Foundation

/// The kernel's process table, read with `sysctl` and libproc rather than by
/// running `ps` or `lsof`.
enum ProcessTable {
    /// Any user's process: `KERN_PROC_PID` needs no privileges, unlike
    /// `proc_pidinfo`, which is refused for other users' processes.
    static func process(_ pid: pid_t) -> RunningProcess? {
        guard pid > 0, let info = kinfo(pid) else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let userID = info.kp_eproc.e_ucred.cr_uid
        return RunningProcess(
            identity: ProcessIdentity(pid: pid, startSeconds: Int(start.tv_sec), startMicroseconds: Int(start.tv_usec)),
            parentPID: info.kp_eproc.e_ppid,
            userID: userID,
            userName: userName(userID),
            shortName: withUnsafeBytes(of: info.kp_proc.p_comm) { string($0) },
            path: path(pid),
            arguments: arguments(pid)
        )
    }

    /// The identity of a live process; nil once it has exited, even while it
    /// waits as a zombie for its parent, since its sockets are closed then.
    static func identity(_ pid: pid_t) -> ProcessIdentity? {
        guard let info = kinfo(pid), info.kp_proc.p_stat != SZOMB else { return nil }
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

    // MARK: - Sockets

    /// The current user's listening TCP sockets, from each process's file
    /// descriptors. Other users' processes can't be read this way.
    static func currentUserListeners() -> [SocketListener] {
        var listeners: [SocketListener] = []
        var seen = Set<SocketListener>()
        for pid in userProcessIDs() {
            for listener in Self.listeners(of: pid) where seen.insert(listener).inserted {
                listeners.append(listener)
            }
        }
        return listeners
    }

    private static func listeners(of pid: pid_t) -> [SocketListener] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let read = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride))
        guard read > 0 else { return [] }

        var listeners: [SocketListener] = []
        for descriptor in descriptors.prefix(Int(read) / stride) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let internet = tcp.tcpsi_ini
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: internet.insi_lport)))
            let host: String
            if internet.insi_vflag & UInt8(INI_IPV6) != 0 {
                host = format(AF_INET6, internet.insi_laddr.ina_6, length: INET6_ADDRSTRLEN)
            } else {
                host = format(AF_INET, internet.insi_laddr.ina_46.i46a_addr4, length: INET_ADDRSTRLEN)
            }
            listeners.append(SocketListener(pid: pid, host: host, port: port))
        }
        return listeners
    }

    private static func format<Address>(_ family: Int32, _ address: Address, length: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(length))
        let formatted = withUnsafeBytes(of: address) { inet_ntop(family, $0.baseAddress, &buffer, socklen_t(length)) }
        return formatted == nil ? "" : string(buffer)
    }

    private static func userProcessIDs() -> ArraySlice<pid_t> {
        let bytesNeeded = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard bytesNeeded > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytesNeeded) / MemoryLayout<pid_t>.size + 64)
        let bytesRead = proc_listpids(
            UInt32(PROC_UID_ONLY), getuid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.size)
        )
        guard bytesRead > 0 else { return [] }
        return pids.prefix(Int(bytesRead) / MemoryLayout<pid_t>.size).filter { $0 > 0 }[...]
    }

    // MARK: - Details

    private static func kinfo(_ pid: pid_t) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        // A PID with no process answers with a size of zero, not an error.
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    private static func path(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return string(buffer)
    }

    private static func arguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return arguments(fromProcArgs: buffer.prefix(size))
    }

    /// `KERN_PROCARGS2` is `argc`, the executable path, padding, then `argc`
    /// NUL-terminated arguments followed by the environment, which is
    /// skipped.
    static func arguments(fromProcArgs buffer: ArraySlice<UInt8>) -> [String]? {
        guard buffer.count > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return nil }
        var index = buffer.startIndex + 4
        while index < buffer.endIndex, buffer[index] != 0 { index += 1 }
        while index < buffer.endIndex, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < buffer.endIndex {
            let end = buffer[index...].firstIndex(of: 0) ?? buffer.endIndex
            arguments.append(String(decoding: buffer[index..<end], as: UTF8.self))
            index = end + 1
        }
        return arguments.isEmpty ? nil : arguments
    }

    private static func userName(_ userID: uid_t) -> String? {
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 1024)
        guard getpwuid_r(userID, &entry, &buffer, buffer.count, &result) == 0, result != nil else { return nil }
        return String(cString: entry.pw_name)
    }

    private static func string(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    private static func string(_ bytes: UnsafeRawBufferPointer) -> String {
        String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}
