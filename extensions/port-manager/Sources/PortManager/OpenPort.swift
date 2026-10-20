import Darwin
import Foundation

/// One port a process listens on, with every address it is bound to there:
/// one row in Open Ports. A dual-stack server's IPv4 and IPv6 sockets share a
/// row.
struct OpenPort: Hashable, Sendable {
    let port: Int
    let pid: pid_t
    /// Sorted, without repeats.
    let hosts: [String]
    /// Nil when the process exited while it was being read.
    let process: RunningProcess?
    let parent: RunningProcess?
    /// The socket table's name for the process, for when it can't be read.
    let listedName: String?

    /// Stable while the process keeps listening; a restarted server gets a
    /// new PID and a new row.
    var id: String { "\(pid):\(port)" }

    var processName: String { process?.name ?? listedName ?? "PID \(pid)" }

    /// The widest reach of any of its addresses.
    var exposure: Exposure { hosts.map(Exposure.init(host:)).max() ?? .localhost }

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

    /// Groups sockets by process and port, sorted by port and then PID, and
    /// reads each process and its parent once.
    static func group(_ sockets: [SocketListener], processes: (pid_t) -> RunningProcess?) -> [OpenPort] {
        var hosts: [String: Set<String>] = [:]
        var first: [String: SocketListener] = [:]
        for socket in sockets {
            let key = "\(socket.pid):\(socket.port)"
            hosts[key, default: []].insert(socket.host)
            if first[key] == nil { first[key] = socket }
        }

        var cache: [pid_t: RunningProcess?] = [:]
        func lookup(_ pid: pid_t) -> RunningProcess? {
            if let cached = cache[pid] { return cached }
            let process = processes(pid)
            cache[pid] = process
            return process
        }

        return first.values
            .sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
            .map { socket in
                let process = lookup(socket.pid)
                return OpenPort(
                    port: socket.port,
                    pid: socket.pid,
                    hosts: hosts["\(socket.pid):\(socket.port)", default: []].sorted(by: Exposure.hostOrder),
                    process: process,
                    parent: process.flatMap { $0.parentPID > 1 ? lookup($0.parentPID) : nil },
                    listedName: socket.processName
                )
            }
    }
}

/// Who can reach a listening socket, judged by the address it is bound to.
/// Ordered from the narrowest reach to the widest.
enum Exposure: Int, Comparable, CaseIterable, Sendable {
    /// `127.0.0.1` or `::1`: only this Mac.
    case localhost
    /// One interface's address, such as a LAN or VPN address.
    case interface
    /// `0.0.0.0` or `::`: every interface, so other devices on the network.
    case network

    init(host: String) {
        let address = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        switch address {
        case "0.0.0.0", "::", "*", "":
            self = .network
        case "::1", "localhost":
            self = .localhost
        default:
            self = address.hasPrefix("127.") || address.hasPrefix("::ffff:127.") ? .localhost : .interface
        }
    }

    static func < (lhs: Exposure, rhs: Exposure) -> Bool { lhs.rawValue < rhs.rawValue }

    /// IPv4 before IPv6, then by text, so a row lists `127.0.0.1` before `::1`.
    static func hostOrder(_ lhs: String, _ rhs: String) -> Bool {
        (lhs.contains(":") ? 1 : 0, lhs) < (rhs.contains(":") ? 1 : 0, rhs)
    }
}
