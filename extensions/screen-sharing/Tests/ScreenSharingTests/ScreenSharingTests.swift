import Foundation
import PrismExtensionKit
import PrismExtensionTesting
import Testing
@testable import ScreenSharing

// MARK: - Fakes

private actor FakeDiscovery: BonjourDiscovering {
    private var responses: [[DiscoveredHost]]
    private var incrementalBatches: [[DiscoveredHost]]
    private(set) var discoverCalls = 0

    init(
        responses: [[DiscoveredHost]] = [[]],
        incrementalBatches: [[DiscoveredHost]] = []
    ) {
        self.responses = responses
        self.incrementalBatches = incrementalBatches
    }

    func setNextResponse(_ hosts: [DiscoveredHost]) {
        responses = [hosts]
    }

    func discover(
        timeout: Duration,
        onUpdate: @escaping @Sendable ([DiscoveredHost]) -> Void
    ) async -> [DiscoveredHost] {
        discoverCalls += 1
        for batch in incrementalBatches {
            onUpdate(batch)
        }
        if responses.count > 1 {
            return responses.removeFirst()
        }
        return responses.first ?? []
    }
}

private actor FakeLauncher: ScreenSharingLaunching {
    private(set) var openedURLs: [URL] = []
    var failure: (any Error)?

    func setFailure(_ error: (any Error)?) {
        failure = error
    }

    func open(_ url: URL) async throws {
        if let failure {
            throw failure
        }
        openedURLs.append(url)
    }
}

private struct FakeLaunchError: LocalizedError {
    let errorDescription: String?
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date = Date(timeIntervalSince1970: 1_760_000_000)) {
        self.current = date
    }

    var now: Date {
        lock.withLock { current }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("prism-screen-sharing-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Address Parsing & Helpers

@Suite("Host address parsing and helpers")
struct HostAddressParserTests {
    @Test("Parses .local hostnames, IPv4, ports, usernames, IPv6, and vnc URLs")
    func parsesValidAddresses() {
        let local = HostAddressParser.parseAddress("spikes-Mac-Mini.local.")
        #expect(local == HostAddress(host: "spikes-Mac-Mini.local", port: 5900))
        #expect(local?.displayAddress == "spikes-Mac-Mini.local")
        #expect(local?.vncURL?.absoluteString == "vnc://spikes-Mac-Mini.local")

        let ipPort = HostAddressParser.parseAddress("192.168.1.20:5901")
        #expect(ipPort == HostAddress(host: "192.168.1.20", port: 5901))
        #expect(ipPort?.displayAddress == "192.168.1.20:5901")
        #expect(ipPort?.vncURL?.absoluteString == "vnc://192.168.1.20:5901")

        let withUser = HostAddressParser.parseAddress("alice@100.64.0.12:5902")
        #expect(withUser == HostAddress(host: "100.64.0.12", port: 5902, username: "alice"))
        #expect(withUser?.vncURL?.absoluteString == "vnc://alice@100.64.0.12:5902")

        let vncURL = HostAddressParser.parseAddress("vnc://bob@studio.local:5900")
        #expect(vncURL == HostAddress(host: "studio.local", port: 5900, username: "bob"))
        #expect(vncURL?.vncURL?.absoluteString == "vnc://bob@studio.local")

        let ipv6Bracketed = HostAddressParser.parseAddress("[fe80::1]:5901")
        #expect(ipv6Bracketed == HostAddress(host: "fe80::1", port: 5901))
        #expect(ipv6Bracketed?.displayAddress == "[fe80::1]:5901")
        #expect(ipv6Bracketed?.stableID == "host:[fe80::1]:5901")
        #expect(HostCatalog.fallbackAddress(forItemID: ipv6Bracketed!.stableID) == ipv6Bracketed)

        let ipv6Bare = HostAddressParser.parseAddress("::1")
        #expect(ipv6Bare == HostAddress(host: "::1", port: 5900))

        let ipv6URL = HostAddressParser.parseAddress("vnc://[::1]:5901")
        #expect(ipv6URL == HostAddress(host: "::1", port: 5901))
        #expect(ipv6URL?.vncURL?.absoluteString == "vnc://[::1]:5901")
    }

    @Test("Rejects ordinary search words and non-vnc schemes")
    func rejectsNonAddresses() {
        #expect(HostAddressParser.parseAddress("") == nil)
        #expect(HostAddressParser.parseAddress("mac mini") == nil)
        #expect(HostAddressParser.parseAddress("studio") == nil)
        #expect(HostAddressParser.parseAddress("http://example.com") == nil)
        #expect(HostAddressParser.parseAddress("999.999.1.1") == nil)
        #expect(HostAddressParser.parseAddress("192.168.1.1:99999") == nil)
    }

    @Test("Parses Saved Hosts entries with optional labels and deduplicates them")
    func parsesSavedHosts() {
        let raw = """
        Mac Studio = mac-studio.local
        Tailscale Mini = 100.64.0.12:5901, alice@10.0.0.5
        Duplicate = mac-studio.local
        not a valid host
        """
        let entries = HostAddressParser.parseSavedHosts(raw)
        #expect(entries.count == 3)
        #expect(entries[0].name == "Mac Studio")
        #expect(entries[0].address == HostAddress(host: "mac-studio.local"))
        #expect(entries[1].name == "Tailscale Mini")
        #expect(entries[1].address == HostAddress(host: "100.64.0.12", port: 5901))
        #expect(entries[2].name == nil)
        #expect(entries[2].address == HostAddress(host: "10.0.0.5", username: "alice"))
    }

    @Test("Maps hardware model identifiers and host names to fitting SF Symbols")
    func mapsDeviceIcons() {
        #expect(DeviceModelIcon.symbol(for: "MacBookPro18,1", name: "Work") == "laptopcomputer")
        #expect(DeviceModelIcon.symbol(for: "Macmini9,1", name: "Server") == "macmini")
        #expect(DeviceModelIcon.symbol(for: nil, name: "spike’s Mac Studio") == "macstudio")
        #expect(DeviceModelIcon.symbol(for: "iMac21,1", name: "Desk") == "desktopcomputer")
        #expect(DeviceModelIcon.symbol(for: nil, name: "100.64.0.12") == "display")
    }

    @Test("Unescapes DNS-SD fullnames containing spaces and UTF-8 bytes")
    func unescapesDNSSDFullname() {
        let fullname = #"spike\226\128\153s\032Mac\032Mini._rfb._tcp.local."#
        #expect(
            DNSSDBrowseOperation.serviceName(fromFullname: fullname, serviceType: "_rfb._tcp.")
                == "spike’s Mac Mini"
        )
    }
}

// MARK: - Extension End-to-End Tests

@Suite("Screen Sharing extension")
struct ScreenSharingTests {
    @Test("Shows clear empty states across filters when no hosts exist")
    func emptyStates() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let discovery = FakeDiscovery(responses: [[]])
        let session = DiscoverySession(discovery: discovery, coldStartWait: .zero, scanDuration: .zero)
        let ext = ScreenSharing(session: session, launcher: FakeLauncher())
        let prism = try await PrismTestHost(ext, dataDirectory: dir)

        let all = try await prism.list(ScreenSharing.CommandID.connections)
        #expect(all.items.isEmpty)
        #expect(all.emptyMessage?.title == "No Macs Found")
        #expect(all.filters.map(\.id) == ["all", "pinned", "local", "recent"])

        let pinned = try await prism.list(ScreenSharing.CommandID.connections, filter: ScreenSharing.FilterID.pinned)
        #expect(pinned.emptyMessage?.title == "No Pinned Hosts")

        let local = try await prism.list(ScreenSharing.CommandID.connections, filter: ScreenSharing.FilterID.local)
        #expect(local.emptyMessage?.title == "No Macs Found Nearby")

        let recent = try await prism.list(ScreenSharing.CommandID.connections, filter: ScreenSharing.FilterID.recent)
        #expect(recent.emptyMessage?.title == "No Recent Connections")

        let unmatched = try await prism.list(ScreenSharing.CommandID.connections, query: "nonexistent mac")
        #expect(unmatched.items.isEmpty)
        #expect(unmatched.emptyMessage?.title == "No Matching Hosts")
    }

    @Test("Lists Bonjour Macs, merges saved hosts, and supports Chinese pinyin search")
    func listsMergedHostsAndSearchesPinyin() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let clock = TestClock()
        let mini = DiscoveredHost(
            serviceName: "书房 Mac Mini",
            address: HostAddress(host: "study-mini.local"),
            model: "Macmini9,1",
            lastSeenAt: clock.now
        )
        let studio = DiscoveredHost(
            serviceName: "Mac Studio",
            address: HostAddress(host: "mac-studio.local"),
            model: "MacStudio1,1",
            lastSeenAt: clock.now
        )
        let discovery = FakeDiscovery(responses: [[mini, studio]], incrementalBatches: [[mini, studio]])
        let session = DiscoverySession(
            discovery: discovery,
            now: { clock.now },
            coldStartWait: .milliseconds(50),
            scanDuration: .zero
        )
        let ext = ScreenSharing(session: session, launcher: FakeLauncher(), now: { clock.now })
        let prism = try await PrismTestHost(
            ext,
            preferences: [
                ScreenSharing.PreferenceID.savedHosts: .string("Tailscale Server = 100.64.0.12:5901"),
            ],
            dataDirectory: dir
        )

        _ = try await prism.list(ScreenSharing.CommandID.connections)
        await session.waitForPendingScan()

        let list = try await prism.list(ScreenSharing.CommandID.connections)
        #expect(list.items.count == 3)
        #expect(list.items.map(\.title) == ["Mac Studio", "书房 Mac Mini", "Tailscale Server"])
        #expect(list.items[0].section == "Local Network")
        #expect(list.items[2].section == "Saved")
        #expect(list.items[1].icon?.symbol == "macmini")

        // Search by full pinyin and initials.
        let fullPinyin = try await prism.list(ScreenSharing.CommandID.connections, query: "shufang")
        #expect(fullPinyin.items.map(\.title) == ["书房 Mac Mini"])

        let initials = try await prism.list(ScreenSharing.CommandID.connections, query: "sf")
        #expect(initials.items.map(\.title) == ["书房 Mac Mini"])

        // Filter to Local Network only.
        let localOnly = try await prism.list(
            ScreenSharing.CommandID.connections,
            filter: ScreenSharing.FilterID.local
        )
        #expect(localOnly.items.map(\.title) == ["Mac Studio", "书房 Mac Mini"])
    }

    @Test("Offers Quick Connect for typed addresses and records recent connections across restarts")
    func quickConnectAndPersistence() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let clock = TestClock()
        let launcher = FakeLauncher()
        let makeExt = {
            let discovery = FakeDiscovery(responses: [[]])
            let session = DiscoverySession(discovery: discovery, now: { clock.now }, coldStartWait: .zero, scanDuration: .zero)
            return ScreenSharing(session: session, launcher: launcher, now: { clock.now })
        }

        let prism = try await PrismTestHost(makeExt(), dataDirectory: dir)

        let queryList = try await prism.list(ScreenSharing.CommandID.connections, query: "100.64.0.88:5901")
        #expect(queryList.items.count == 1)
        let quickItem = try #require(queryList.items.first)
        #expect(quickItem.title == "Connect to 100.64.0.88:5901")
        #expect(quickItem.section == "Quick Connect")

        let connectResult = try await prism.perform(
            ScreenSharing.ActionID.connect,
            on: quickItem.id,
            in: ScreenSharing.CommandID.connections
        )
        #expect(connectResult == .done)
        #expect(await launcher.openedURLs.map(\.absoluteString) == ["vnc://100.64.0.88:5901"])

        // Restart the extension process: recent host must survive via Prism state.
        try await prism.restart(with: makeExt())
        let afterRestart = try await prism.list(
            ScreenSharing.CommandID.connections,
            filter: ScreenSharing.FilterID.recent
        )
        #expect(afterRestart.items.count == 1)
        #expect(afterRestart.items[0].title == "100.64.0.88:5901")

        // Searching the exact same address now matches the saved recent item without duplicating Quick Connect.
        let deduped = try await prism.list(ScreenSharing.CommandID.connections, query: "100.64.0.88:5901")
        #expect(deduped.items.count == 1)
        #expect(deduped.items[0].id == HostAddress(host: "100.64.0.88", port: 5901).stableID)
    }

    @Test("Pins, unpins, and removes recent connections")
    func pinUnpinAndRemoveRecent() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let clock = TestClock()
        let mini = DiscoveredHost(
            serviceName: "Office Mini",
            address: HostAddress(host: "office-mini.local"),
            model: "Macmini9,1",
            lastSeenAt: clock.now
        )
        let discovery = FakeDiscovery(responses: [[mini]], incrementalBatches: [[mini]])
        let session = DiscoverySession(discovery: discovery, now: { clock.now }, coldStartWait: .milliseconds(50), scanDuration: .zero)
        let launcher = FakeLauncher()
        let ext = ScreenSharing(session: session, launcher: launcher, now: { clock.now })
        let prism = try await PrismTestHost(ext, dataDirectory: dir)

        _ = try await prism.list(ScreenSharing.CommandID.connections)
        await session.waitForPendingScan()

        let miniID = mini.id

        // Connect to add to Recent, then pin it.
        _ = try await prism.perform(ScreenSharing.ActionID.connect, on: miniID, in: ScreenSharing.CommandID.connections)
        let pinResult = try await prism.perform(ScreenSharing.ActionID.togglePin, on: miniID, in: ScreenSharing.CommandID.connections)
        #expect(pinResult.reload == true)
        #expect(pinResult.result == .keepOpen(message: "Pinned “Office Mini”."))

        let pinnedList = try await prism.list(ScreenSharing.CommandID.connections, filter: ScreenSharing.FilterID.pinned)
        #expect(pinnedList.items.map(\.id) == [miniID])

        // Removing from Recent keeps it pinned.
        let removeResult = try await prism.perform(ScreenSharing.ActionID.removeRecent, on: miniID, in: ScreenSharing.CommandID.connections)
        #expect(removeResult.reload == true)

        let recentList = try await prism.list(ScreenSharing.CommandID.connections, filter: ScreenSharing.FilterID.recent)
        #expect(recentList.items.isEmpty)

        let stillPinned = try await prism.list(ScreenSharing.CommandID.connections, filter: ScreenSharing.FilterID.pinned)
        #expect(stillPinned.items.map(\.id) == [miniID])

        // Unpin removes it from Pinned.
        let unpinResult = try await prism.perform(ScreenSharing.ActionID.togglePin, on: miniID, in: ScreenSharing.CommandID.connections)
        #expect(unpinResult.result == .keepOpen(message: "Unpinned “Office Mini”."))
        let noPinned = try await prism.list(ScreenSharing.CommandID.connections, filter: ScreenSharing.FilterID.pinned)
        #expect(noPinned.items.isEmpty)
    }

    @Test("Reports launcher failure without recording a recent connection")
    func launcherFailure() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let launcher = FakeLauncher()
        await launcher.setFailure(FakeLaunchError(errorDescription: "Screen Sharing unavailable"))
        let session = DiscoverySession(discovery: FakeDiscovery(responses: [[]]), coldStartWait: .zero, scanDuration: .zero)
        let ext = ScreenSharing(session: session, launcher: launcher)
        let prism = try await PrismTestHost(ext, dataDirectory: dir)

        let result = try await prism.perform(
            ScreenSharing.ActionID.connect,
            on: "quick:192.168.1.50",
            in: ScreenSharing.CommandID.connections
        )
        #expect(result.result == .failed(message: "Couldn’t open Screen Sharing for “192.168.1.50”: Screen Sharing unavailable"))

        let recent = try await prism.list(ScreenSharing.CommandID.connections, filter: ScreenSharing.FilterID.recent)
        #expect(recent.items.isEmpty)
    }

    @Test("Refreshes local network and updates saved hosts when preferences change")
    func refreshAndPreferenceUpdates() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let clock = TestClock()
        let discovery = FakeDiscovery(responses: [[]])
        let session = DiscoverySession(discovery: discovery, now: { clock.now }, coldStartWait: .zero, scanDuration: .zero)
        let ext = ScreenSharing(session: session, launcher: FakeLauncher(), now: { clock.now })
        let prism = try await PrismTestHost(ext, dataDirectory: dir)

        let initial = try await prism.list(ScreenSharing.CommandID.connections)
        await session.waitForPendingScan()
        #expect(initial.items.isEmpty)

        // Update preferences to add a saved host.
        try await prism.setPreferences([
            ScreenSharing.PreferenceID.savedHosts: .string("Studio = studio.local"),
        ])
        let withSaved = try await prism.list(ScreenSharing.CommandID.connections)
        #expect(withSaved.items.map(\.title) == ["Studio"])

        // New Mac comes online and user refreshes with ⌘R.
        let newMac = DiscoveredHost(
            serviceName: "Lab MacBook",
            address: HostAddress(host: "lab-macbook.local"),
            model: "MacBookPro18,1",
            lastSeenAt: clock.now
        )
        await discovery.setNextResponse([newMac])
        let refreshResult = try await prism.perform(
            ScreenSharing.ActionID.refresh,
            on: HostAddress(host: "studio.local").stableID,
            in: ScreenSharing.CommandID.connections
        )
        await session.waitForPendingScan()
        #expect(refreshResult.reload == true)

        let afterRefresh = try await prism.list(ScreenSharing.CommandID.connections)
        #expect(afterRefresh.items.map(\.title) == ["Lab MacBook", "Studio"])
    }

    @Test("Translates runtime strings for Simplified and Traditional Chinese")
    func chineseLocalizations() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let session = DiscoverySession(discovery: FakeDiscovery(responses: [[]]), coldStartWait: .zero, scanDuration: .zero)
        let ext = ScreenSharing(session: session, launcher: FakeLauncher())

        let zhHans = try await PrismTestHost(ext, dataDirectory: dir, language: "zh-Hans")
        let hansList = try await zhHans.list(ScreenSharing.CommandID.connections)
        #expect(hansList.emptyMessage?.title == "未找到 Mac")
        #expect(hansList.filters.map(\.title) == ["全部", "已置顶", "局域网", "最近连接"])

        let zhHant = try await PrismTestHost(ext, dataDirectory: dir, language: "zh-Hant")
        let hantList = try await zhHant.list(ScreenSharing.CommandID.connections)
        #expect(hantList.emptyMessage?.title == "找不到 Mac")
        #expect(hantList.filters.map(\.title) == ["全部", "已釘選", "區域網路", "最近連線"])
    }
}
