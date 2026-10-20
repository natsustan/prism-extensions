import Foundation

/// Reads listening sockets from `netstat -anv -p tcp`, which lists every
/// user's sockets with the PID that owns each, without root.
enum Netstat {
    static let executable = URL(fileURLWithPath: "/usr/sbin/netstat")
    static let arguments = ["-anv", "-p", "tcp"]

    /// The listening sockets in `output`, or nil when its header isn't one
    /// this parser knows, so the caller can read the sockets another way.
    static func listeners(in output: String) -> [SocketListener]? {
        let lines = output.split(whereSeparator: \.isNewline)
        guard let header = lines.first(where: { $0.hasPrefix("Proto ") }) else { return nil }
        let headerColumns = header.split(whereSeparator: \.isWhitespace)

        // Values start at the same index as their header word, less one for
        // each of the two-word "Local Address" and "Foreign Address".
        let owner: (_ columns: [Substring]) -> (name: String?, pid: pid_t)?
        if let processHeader = headerColumns.firstIndex(of: "process:pid") {
            // macOS 13 and later: one right-aligned `name:pid` column. The
            // name is the kernel's 16-character one and may hold spaces, so it
            // runs up to the first `:<digits>` word.
            let processColumn = processHeader - 2
            guard processColumn > 5 else { return nil }
            owner = { columns in
                var words: [Substring] = []
                for column in columns.dropFirst(processColumn) {
                    if let colon = column.lastIndex(of: ":"), let pid = pid_t(column[column.index(after: colon)...]) {
                        let name = (words + [column[..<colon]]).joined(separator: " ")
                        return (name.isEmpty ? nil : name, pid)
                    }
                    words.append(column)
                }
                return nil
            }
        } else if let pidHeader = headerColumns.firstIndex(of: "pid") {
            // Older systems: a bare `pid` column.
            let pidColumn = pidHeader - 2
            guard pidColumn > 5 else { return nil }
            owner = { columns in
                guard columns.count > pidColumn, let pid = pid_t(columns[pidColumn]) else { return nil }
                return (nil, pid)
            }
        } else {
            return nil
        }

        var listeners: [SocketListener] = []
        var seen = Set<SocketListener>()
        for line in lines {
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count > 5, columns[0].hasPrefix("tcp"), columns[5] == "LISTEN",
                  let (host, port) = address(columns[3], family: columns[0]),
                  let (name, pid) = owner(columns), pid > 0 else { continue }
            let listener = SocketListener(pid: pid, host: host, port: port, processName: name)
            if seen.insert(listener).inserted { listeners.append(listener) }
        }
        return listeners
    }

    /// `127.0.0.1.3000`, `*.5000`, `::1.8080`, `fe80::1%lo0.631`: the port
    /// follows the last dot. A wildcard becomes the family's any-address.
    static func address(_ value: Substring, family: Substring) -> (host: String, port: Int)? {
        guard let dot = value.lastIndex(of: "."), let port = Int(value[value.index(after: dot)...]),
              (0...65535).contains(port) else { return nil }
        let host = String(value[..<dot])
        guard !host.isEmpty else { return nil }
        if host == "*" { return (family == "tcp4" ? "0.0.0.0" : "::", port) }
        return (host, port)
    }
}
