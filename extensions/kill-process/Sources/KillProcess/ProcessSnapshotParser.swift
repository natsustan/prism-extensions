import Darwin
import Foundation

/// One row parsed from `LC_ALL=C /bin/ps -axo pid=,ppid=,uid=,stat=,pcpu=,rss=,comm=`.
struct ParsedPSRow: Equatable, Sendable {
    let pid: pid_t
    let parentPID: pid_t
    let userID: uid_t
    let stat: String
    let cpu: Double
    let memoryBytes: UInt64
    let comm: String
}

/// Parses `ps` snapshot output without splitting spaces inside executable paths.
enum ProcessSnapshotParser {
    static func parse(_ output: String) -> [ParsedPSRow] {
        var rows: [ParsedPSRow] = []
        output.enumerateLines { line, _ in
            if let row = parseLine(line) {
                rows.append(row)
            }
        }
        return rows
    }

    static func parseLine(_ line: String) -> ParsedPSRow? {
        var index = line.startIndex
        let end = line.endIndex

        func nextToken() -> Substring? {
            while index < end, line[index].isWhitespace {
                index = line.index(after: index)
            }
            guard index < end else { return nil }
            let start = index
            while index < end, !line[index].isWhitespace {
                index = line.index(after: index)
            }
            return line[start..<index]
        }

        guard let pidText = nextToken(), let pid = pid_t(pidText), pid > 0,
              let ppidText = nextToken(), let parentPID = pid_t(ppidText),
              let uidText = nextToken(), let userID = uid_t(uidText),
              let statText = nextToken(), !statText.contains("Z"),
              let cpuText = nextToken(),
              let rssText = nextToken(), let rssKiB = UInt64(rssText) else {
            return nil
        }

        let normalizedCPU = cpuText.contains(",")
            ? cpuText.replacingOccurrences(of: ",", with: ".")
            : String(cpuText)
        guard let cpu = Double(normalizedCPU), cpu.isFinite, cpu >= 0 else {
            return nil
        }

        while index < end, line[index].isWhitespace {
            index = line.index(after: index)
        }
        let comm = String(line[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !comm.isEmpty else { return nil }

        let (memoryBytes, overflow) = rssKiB.multipliedReportingOverflow(by: 1024)
        return ParsedPSRow(
            pid: pid,
            parentPID: parentPID,
            userID: userID,
            stat: String(statText),
            cpu: cpu,
            memoryBytes: overflow ? UInt64.max : memoryBytes,
            comm: comm
        )
    }
}
