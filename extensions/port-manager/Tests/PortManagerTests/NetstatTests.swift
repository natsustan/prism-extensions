import Testing
@testable import PortManager

@Suite("Reading the system")
struct NetstatTests {
    /// `netstat -anv -p tcp` on macOS 26, trimmed.
    let current = """
    Active Internet connections (including servers)
    Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)          rxbytes      txbytes  rhiwat  shiwat          process:pid    state  options           gencnt    flags   flags1 usecnt rtncnt fltrs
    tcp4       0   1553  172.16.10.20.53105     2.27.217.27.20023      SYN_SENT               0         1553  131872  131872            Surge:1111   00100 00000008 0000000000009db0 00080081 04000900      2      0 000000
    tcp4       0      0  127.0.0.1.7265         *.*                    LISTEN                 0            0  131072  131072             node:2066   00100 00000106 00000000000043ba 00000001 00000800      1      0 000000
    tcp46      0      0  *.51931                *.*                    LISTEN                 0            0  131072  131072         rapportd:661    00100 00000006 000000000000172e 00000000 00080800      1      0 000000
    tcp6       0      0  *.5000                 *.*                    LISTEN                 0            0  131072  131072    ControlCenter:721    00100 00000006 00000000000010f6 00000001 00000800      1      0 000000
    tcp4       0      0  *.5000                 *.*                    LISTEN                 0            0  131072  131072    ControlCenter:721    00100 00000006 00000000000010f5 00000001 00000800      1      0 000000
    tcp6       0      0  ::1.9229               *.*                    LISTEN                 0            0  131072  131072  Google Chrome H:812    00100 00000006 0000000000002b4b 00000001 00000800      1      0 000000
    tcp6       0      0  fe80::1%lo0.631        *.*                    LISTEN                 0            0  131072  131072            cupsd:300    00100 00000006 0000000000002b4c 00000001 00000800      1      0 000000
    tcp4       0      0  *.22                   *.*                    LISTEN                 0            0  131072  131072          launchd:1      00180 00000006 0000000000000736 00000000 00000800      1      0 000000
    tcp4       0      0  *.22                   *.*                    LISTEN                 0            0  131072  131072          launchd:1      00180 00000006 0000000000000736 00000000 00000800      1      0 000000
    tcp4       0      0  127.0.0.1.7265         127.0.0.1.50122        ESTABLISHED       1200          800  131072  131072             node:2066   00102 00000106 00000000000043bb 00000001 00000800      1      0 000000
    """

    @Test("reads every listening socket from today's netstat, with names that hold spaces")
    func currentFormat() throws {
        let listeners = try #require(Netstat.listeners(in: current))
        #expect(listeners == [
            SocketListener(pid: 2066, host: "127.0.0.1", port: 7265, processName: "node"),
            SocketListener(pid: 661, host: "::", port: 51931, processName: "rapportd"),
            SocketListener(pid: 721, host: "::", port: 5000, processName: "ControlCenter"),
            SocketListener(pid: 721, host: "0.0.0.0", port: 5000, processName: "ControlCenter"),
            SocketListener(pid: 812, host: "::1", port: 9229, processName: "Google Chrome H"),
            SocketListener(pid: 300, host: "fe80::1%lo0", port: 631, processName: "cupsd"),
            SocketListener(pid: 1, host: "0.0.0.0", port: 22, processName: "launchd"),
        ])
    }

    @Test("reads the bare pid column of older systems")
    func olderFormat() {
        let older = """
        Active Internet connections (including servers)
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)     rhiwat shiwat    pid   epid  state    options
        tcp4       0      0  127.0.0.1.3000         *.*                    LISTEN      131072 131072    42      0 0x0100 0x00000106
        tcp6       0      0  ::1.3001               *.*                    LISTEN      131072 131072    42      0 0x0100 0x00000106
        tcp4       0      0  127.0.0.1.9000         10.0.0.1.80            ESTABLISHED 131072 131072    99      0 0x0102 0x00000106
        tcp4       0      0  malformed              *.*                    LISTEN      131072 131072    50      0 0x0100 0x00000106
        """
        #expect(Netstat.listeners(in: older) == [
            SocketListener(pid: 42, host: "127.0.0.1", port: 3000),
            SocketListener(pid: 42, host: "::1", port: 3001),
        ])
    }

    @Test("output it can't read is nil, so the caller looks another way")
    func unreadable() {
        #expect(Netstat.listeners(in: "") == nil)
        #expect(Netstat.listeners(in: "Proto Recv-Q Send-Q Local Address Foreign Address (state)\n") == nil)
        // The header with no sockets, as netstat prints when the socket table is hidden.
        #expect(Netstat.listeners(in: String(current.split(separator: "\n").prefix(2).joined(separator: "\n"))) == [])
    }

    @Test("sockets netstat missed are added from the user's own, without repeats")
    func merge() {
        let everyone = [SocketListener(pid: 1, host: "0.0.0.0", port: 22, processName: "launchd"),
                        SocketListener(pid: 7, host: "127.0.0.1", port: 3000, processName: "node")]
        let own = [SocketListener(pid: 7, host: "127.0.0.1", port: 3000), SocketListener(pid: 7, host: "::1", port: 3000)]
        #expect(SystemPorts.merge(everyone, own) == everyone + [SocketListener(pid: 7, host: "::1", port: 3000)])
        #expect(SystemPorts.merge([], own) == own)
    }

    @Test("a process's arguments are read from KERN_PROCARGS2, without its environment")
    func procArgs() {
        var buffer: [UInt8] = withUnsafeBytes(of: Int32(3)) { Array($0) }
        buffer += Array("/usr/local/bin/node".utf8) + [0, 0, 0, 0]
        for word in ["node", "server.js", "--title=My App", "HOME=/Users/jane"] { buffer += Array(word.utf8) + [0] }
        #expect(ProcessTable.arguments(fromProcArgs: buffer[...]) == ["node", "server.js", "--title=My App"])
        #expect(ProcessTable.arguments(fromProcArgs: [0, 0][...]) == nil)
    }

    @Test("an address's reach follows from what it is bound to")
    func exposure() {
        #expect(["127.0.0.1", "127.0.1.1", "::1", "::ffff:127.0.0.1"].map(Exposure.init(host:)).allSatisfy { $0 == .localhost })
        #expect(["0.0.0.0", "::", "*"].map(Exposure.init(host:)).allSatisfy { $0 == .network })
        #expect(["192.168.1.20", "fe80::1%lo0", "100.64.0.3"].map(Exposure.init(host:)).allSatisfy { $0 == .interface })
    }

    @Test("Port Names reads ports and names in the ways people write them")
    func portNames() {
        let names = PortNames("3000 Web, 5432=Postgres; 6379: Redis\n8080 Proxy, 3000 Other, abc, 99999 Huge, 4000")
        #expect(names.names == [3000: "Web", 5432: "Postgres", 6379: "Redis", 8080: "Proxy"])
        #expect(PortNames("").names.isEmpty)
    }

    @Test("a command line holding backticks gets a longer fence")
    func codeBlock() {
        #expect(PortRows.codeBlock("sh -c 'echo ```'") == "````\nsh -c 'echo ```'\n````")
    }
}
