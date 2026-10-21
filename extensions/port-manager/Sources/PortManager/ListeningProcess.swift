import Darwin
import Foundation

/// A process and the ports it listens on: one row in Open Ports.
struct ListeningProcess: Hashable, Sendable {
    let pid: pid_t
    /// Sorted by port.
    let ports: [ListeningPort]
    /// Nil when the process exited while it was being read.
    let process: RunningProcess?
    let parent: RunningProcess?
    /// The socket table's name for the process, for when it can't be read.
    let listedName: String?

    /// The PID and the start time, so a row names one process for as long
    /// as it runs, and never the next one to get its PID.
    var id: String {
        guard let identity = process?.identity else { return "\(pid)" }
        return "\(pid)@\(identity.startSeconds).\(identity.startMicroseconds)"
    }

    var processName: String { process?.name ?? listedName ?? "PID \(pid)" }

    /// The ports that reach as far as `exposure`, in order.
    func ports(reaching exposure: Exposure) -> [ListeningPort] {
        ports.filter { $0.exposure == exposure }
    }

    /// Groups sockets by process, sorted by each one's lowest port, and reads
    /// each process and its parent once.
    static func group(_ sockets: [SocketListener], processes: (pid_t) -> RunningProcess?) -> [ListeningProcess] {
        var hosts: [pid_t: [Int: Set<String>]] = [:]
        var listedNames: [pid_t: String] = [:]
        for socket in sockets {
            hosts[socket.pid, default: [:]][socket.port, default: []].insert(socket.host)
            if let name = socket.processName, listedNames[socket.pid] == nil { listedNames[socket.pid] = name }
        }

        var cache: [pid_t: RunningProcess?] = [:]
        func lookup(_ pid: pid_t) -> RunningProcess? {
            if let cached = cache[pid] { return cached }
            let process = processes(pid)
            cache[pid] = process
            return process
        }

        return hosts
            .map { pid, ports in
                let process = lookup(pid)
                return ListeningProcess(
                    pid: pid,
                    ports: ports.keys.sorted().map { ListeningPort(port: $0, hosts: ports[$0]!.sorted(by: Exposure.hostOrder)) },
                    process: process,
                    parent: process.flatMap { $0.parentPID > 1 ? lookup($0.parentPID) : nil },
                    listedName: listedNames[pid]
                )
            }
            .sorted(by: byLowestPort)
    }

    static func byLowestPort(_ lhs: ListeningProcess, _ rhs: ListeningProcess) -> Bool {
        byLowestPort((lhs, lhs.ports), (rhs, rhs.ports))
    }

    /// Rows showing `ports` of a process, by the lowest of them.
    static func byLowestPort(
        _ lhs: (process: ListeningProcess, ports: [ListeningPort]), _ rhs: (process: ListeningProcess, ports: [ListeningPort])
    ) -> Bool {
        (lhs.ports[0].port, lhs.process.pid) < (rhs.ports[0].port, rhs.process.pid)
    }
}

/// One port and every address it is bound to there: a dual-stack server's
/// IPv4 and IPv6 sockets are one port.
struct ListeningPort: Hashable, Sendable {
    let port: Int
    /// Sorted, without repeats.
    let hosts: [String]
    /// The widest reach of any of its addresses.
    let exposure: Exposure

    init(port: Int, hosts: [String]) {
        self.port = port
        self.hosts = hosts
        exposure = hosts.map(Exposure.init(host:)).max() ?? .localhost
    }

    /// Each address with the port, as a browser or `netstat` writes it.
    var addresses: [String] { hosts.map { Self.address(host: $0, port: port) } }

    /// The address a browser on this Mac can reach it at: localhost, unless
    /// it listens only on one interface's address.
    var url: URL? {
        let answersLocally = hosts.contains { Exposure(host: $0) != .interface }
        let host = answersLocally ? "localhost" : hosts.first ?? "localhost"
        return URL(string: "http://\(Self.address(host: host, port: port))")
    }

    static func address(host: String, port: Int) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

/// Who can reach a listening socket, judged by the address it is bound to.
/// Ordered from the narrowest reach to the widest.
enum Exposure: Comparable, Sendable {
    /// `127.0.0.1` or `::1`: only this Mac.
    case localhost
    /// One interface's address, such as a LAN or VPN address.
    case interface
    /// `0.0.0.0` or `::`: every interface, so other devices on the network.
    case network

    init(host: String) {
        let parts = host.split(separator: "%", maxSplits: 1).map(String.init)
        let address = parts.first ?? host
        // A link-local address on the loopback interface, as cupsd binds.
        if parts.count == 2, parts[1] == "lo0" {
            self = .localhost
            return
        }
        switch address {
        case "0.0.0.0", "::", "*", "":
            self = .network
        case "::1", "localhost":
            self = .localhost
        default:
            self = address.hasPrefix("127.") || address.hasPrefix("::ffff:127.") ? .localhost : .interface
        }
    }

    /// IPv4 before IPv6, then by text, so a port lists `127.0.0.1` before `::1`.
    static func hostOrder(_ lhs: String, _ rhs: String) -> Bool {
        (lhs.contains(":") ? 1 : 0, lhs) < (rhs.contains(":") ? 1 : 0, rhs)
    }
}
