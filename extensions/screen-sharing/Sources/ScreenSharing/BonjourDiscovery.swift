import dnssd
import Foundation
import PrismExtensionKit

/// Discovers Macs advertising Screen Sharing (`_rfb._tcp.`) on the local network.
protocol BonjourDiscovering: Sendable {
    /// Runs a bounded Bonjour browse + resolve pass, invoking `onUpdate` as
    /// hosts are resolved and returning the final snapshot when finished.
    func discover(
        timeout: Duration,
        onUpdate: @escaping @Sendable ([DiscoveredHost]) -> Void
    ) async -> [DiscoveredHost]
}

/// Native macOS Bonjour browser backed by `libsystem_dnssd` (`DNSServiceBrowse`
/// + `DNSServiceResolve`), requiring no spawned child processes.
struct DNSSDBonjourDiscovery: BonjourDiscovering {
    let localHostName: String
    let now: @Sendable () -> Date

    init(
        localHostName: String = ProcessInfo.processInfo.hostName,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.localHostName = HostAddress.normalizeHost(localHostName).lowercased()
        self.now = now
    }

    func discover(
        timeout: Duration,
        onUpdate: @escaping @Sendable ([DiscoveredHost]) -> Void
    ) async -> [DiscoveredHost] {
        let operation = DNSSDBrowseOperation(
            localHostName: localHostName,
            now: now,
            onUpdate: onUpdate
        )

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                operation.start(timeout: timeout) { hosts in
                    continuation.resume(returning: hosts)
                }
            }
        } onCancel: {
            operation.cancel()
        }
    }
}

/// Coordinates the C callbacks for one bounded browse pass on a single serial
/// dispatch queue so every `DNSServiceRef` is created, read, and deallocated
/// exclusively on that queue.
final class DNSSDBrowseOperation: @unchecked Sendable {
    private static let rfbServiceType = "_rfb._tcp."
    private static let deviceInfoServiceType = "_device-info._tcp."

    private let queue = DispatchQueue(label: "prism.screen-sharing.bonjour")
    private let localHostName: String
    private let now: @Sendable () -> Date
    private let onUpdate: @Sendable ([DiscoveredHost]) -> Void

    // All mutable fields below are touched only on `queue`.
    private var browseRefs: [DNSServiceRef] = []
    private var resolveRefs: [DNSServiceRef] = []
    private var rfbHostsByName: [String: (address: HostAddress, lastSeenAt: Date)] = [:]
    private var modelsByName: [String: String] = [:]
    private var lastPublished: [DiscoveredHost] = []
    private var timer: DispatchSourceTimer?
    private var completion: (@Sendable ([DiscoveredHost]) -> Void)?
    private var finished = false
    private var retainedSelf: Unmanaged<DNSSDBrowseOperation>?

    init(
        localHostName: String,
        now: @escaping @Sendable () -> Date,
        onUpdate: @escaping @Sendable ([DiscoveredHost]) -> Void
    ) {
        self.localHostName = localHostName
        self.now = now
        self.onUpdate = onUpdate
    }

    func start(timeout: Duration, completion: @escaping @Sendable ([DiscoveredHost]) -> Void) {
        queue.async { [self] in
            guard !self.finished else {
                completion([])
                return
            }
            self.completion = completion
            // Retain self while any C callback holds an unretained pointer.
            // Released inside `finish()` after all DNSServiceRefs are deallocated.
            self.retainedSelf = Unmanaged.passRetained(self)
            let rawSelf = self.retainedSelf!.toOpaque()

            let rfbStarted = self.startBrowse(
                serviceType: Self.rfbServiceType,
                callback: rfbBrowseCallback,
                rawSelf: rawSelf
            )
            guard rfbStarted else {
                self.finish()
                return
            }

            _ = self.startBrowse(
                serviceType: Self.deviceInfoServiceType,
                callback: deviceInfoBrowseCallback,
                rawSelf: rawSelf
            )

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            let nanoseconds = max(1, Int(timeout.components.seconds * 1_000_000_000 + timeout.components.attoseconds / 1_000_000_000))
            timer.schedule(deadline: .now() + .nanoseconds(nanoseconds))
            timer.setEventHandler { [weak self = self] in
                self?.finish()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func cancel() {
        queue.async {
            self.finish()
        }
    }

    private func startBrowse(
        serviceType: String,
        callback: DNSServiceBrowseReply,
        rawSelf: UnsafeMutableRawPointer
    ) -> Bool {
        var browseRef: DNSServiceRef?
        let err = DNSServiceBrowse(&browseRef, 0, 0, serviceType, "local.", callback, rawSelf)
        guard err == kDNSServiceErr_NoError, let ref = browseRef else {
            return false
        }
        DNSServiceSetDispatchQueue(ref, queue)
        browseRefs.append(ref)
        return true
    }

    fileprivate func startResolve(
        flags: DNSServiceFlags,
        interfaceIndex: UInt32,
        name: String,
        regtype: String,
        domain: String,
        callback: DNSServiceResolveReply
    ) {
        guard !finished, (flags & kDNSServiceFlagsAdd) != 0, let rawSelf = retainedSelf?.toOpaque() else {
            return
        }
        var resolveRef: DNSServiceRef?
        let err = DNSServiceResolve(&resolveRef, 0, interfaceIndex, name, regtype, domain, callback, rawSelf)
        if err == kDNSServiceErr_NoError, let ref = resolveRef {
            DNSServiceSetDispatchQueue(ref, queue)
            resolveRefs.append(ref)
        }
    }

    fileprivate func handleRFBResolve(
        ref: DNSServiceRef?,
        fullname: String?,
        hosttarget: String?,
        port: UInt16
    ) {
        deallocateResolveRef(ref)
        guard !finished, let fullname, let hosttarget else { return }

        let serviceName = Self.serviceName(fromFullname: fullname, serviceType: Self.rfbServiceType)
        let normalizedHost = HostAddress.normalizeHost(hosttarget)
        guard !normalizedHost.isEmpty else { return }

        // Exclude this Mac itself so users don't accidentally connect to their own screen.
        if !localHostName.isEmpty, normalizedHost.lowercased() == localHostName {
            return
        }

        let hostPort = Int(UInt16(bigEndian: port))
        let address = HostAddress(host: normalizedHost, port: hostPort)
        rfbHostsByName[serviceName] = (address: address, lastSeenAt: now())
        publishIfChanged()
    }

    fileprivate func handleDeviceInfoResolve(
        ref: DNSServiceRef?,
        fullname: String?,
        txtLen: UInt16,
        txtRecord: UnsafePointer<UInt8>?
    ) {
        deallocateResolveRef(ref)
        guard !finished, let fullname, let txtRecord, txtLen > 0 else { return }

        let serviceName = Self.serviceName(fromFullname: fullname, serviceType: Self.deviceInfoServiceType)
        var valueLen: UInt8 = 0
        guard let ptr = TXTRecordGetValuePtr(txtLen, txtRecord, "model", &valueLen), valueLen > 0 else {
            return
        }
        let bytes = UnsafeBufferPointer(
            start: ptr.assumingMemoryBound(to: UInt8.self),
            count: Int(valueLen)
        )
        guard let model = String(bytes: bytes, encoding: .utf8), !model.isEmpty else {
            return
        }
        modelsByName[serviceName] = model
        if rfbHostsByName[serviceName] != nil {
            publishIfChanged()
        }
    }

    private func deallocateResolveRef(_ ref: DNSServiceRef?) {
        guard let ref else { return }
        if let index = resolveRefs.firstIndex(where: { $0 == ref }) {
            resolveRefs.remove(at: index)
        }
        DNSServiceRefDeallocate(ref)
    }

    private func currentSnapshot() -> [DiscoveredHost] {
        var seenIDs = Set<String>()
        var hosts = [DiscoveredHost]()
        for (name, entry) in rfbHostsByName.sorted(by: {
            $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
        }) {
            let host = DiscoveredHost(
                serviceName: name,
                address: entry.address,
                model: modelsByName[name],
                lastSeenAt: entry.lastSeenAt
            )
            if seenIDs.insert(host.id).inserted {
                hosts.append(host)
            }
        }
        return hosts
    }

    private func publishIfChanged() {
        let snapshot = currentSnapshot()
        guard snapshot != lastPublished else { return }
        lastPublished = snapshot
        onUpdate(snapshot)
    }

    private func finish() {
        guard !finished else { return }
        finished = true

        timer?.cancel()
        timer = nil

        for ref in browseRefs {
            DNSServiceRefDeallocate(ref)
        }
        browseRefs.removeAll()

        for ref in resolveRefs {
            DNSServiceRefDeallocate(ref)
        }
        resolveRefs.removeAll()

        let snapshot = currentSnapshot()
        let callback = completion
        completion = nil

        // All DNSServiceRefs are deallocated; safe to drop the self-retain.
        retainedSelf?.release()
        retainedSelf = nil

        callback?(snapshot)
    }

    /// Unescapes the instance name prefix from a DNS-SD fullname such as
    /// `spike\226\128\153s\032Mac\032Mini._rfb._tcp.local.`.
    static func serviceName(fromFullname fullname: String, serviceType: String) -> String {
        let marker = ".\(serviceType)"
        let rawPrefix: Substring
        if let range = fullname.range(of: marker, options: .backwards) {
            rawPrefix = fullname[..<range.lowerBound]
        } else {
            rawPrefix = fullname[...]
        }
        return unescapeDNSSDLabel(String(rawPrefix))
    }

    /// DNS-SD escapes spaces and non-ASCII UTF-8 bytes in fullnames as `\DDD`
    /// decimal byte escapes (e.g. `\032` for space) and `\.` / `\\`.
    static func unescapeDNSSDLabel(_ text: String) -> String {
        var bytes = [UInt8]()
        let scalars = Array(text.utf8)
        var i = 0
        while i < scalars.count {
            if scalars[i] == UInt8(ascii: "\\"), i + 1 < scalars.count {
                if i + 3 < scalars.count,
                   let d1 = digit(scalars[i + 1]),
                   let d2 = digit(scalars[i + 2]),
                   let d3 = digit(scalars[i + 3]) {
                    let value = d1 * 100 + d2 * 10 + d3
                    if value <= 255 {
                        bytes.append(UInt8(value))
                        i += 4
                        continue
                    }
                }
                bytes.append(scalars[i + 1])
                i += 2
            } else {
                bytes.append(scalars[i])
                i += 1
            }
        }
        return String(bytes: bytes, encoding: .utf8) ?? text
    }

    private static func digit(_ byte: UInt8) -> Int? {
        guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
        return Int(byte - UInt8(ascii: "0"))
    }
}

private func rfbBrowseCallback(
    _ sdRef: DNSServiceRef?,
    _ flags: DNSServiceFlags,
    _ interfaceIndex: UInt32,
    _ errorCode: DNSServiceErrorType,
    _ serviceName: UnsafePointer<CChar>?,
    _ regtype: UnsafePointer<CChar>?,
    _ replyDomain: UnsafePointer<CChar>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard errorCode == kDNSServiceErr_NoError,
          let context, let serviceName, let regtype, let replyDomain else {
        return
    }
    let op = Unmanaged<DNSSDBrowseOperation>.fromOpaque(context).takeUnretainedValue()
    op.startResolve(
        flags: flags,
        interfaceIndex: interfaceIndex,
        name: String(cString: serviceName),
        regtype: String(cString: regtype),
        domain: String(cString: replyDomain),
        callback: rfbResolveCallback
    )
}

private func deviceInfoBrowseCallback(
    _ sdRef: DNSServiceRef?,
    _ flags: DNSServiceFlags,
    _ interfaceIndex: UInt32,
    _ errorCode: DNSServiceErrorType,
    _ serviceName: UnsafePointer<CChar>?,
    _ regtype: UnsafePointer<CChar>?,
    _ replyDomain: UnsafePointer<CChar>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard errorCode == kDNSServiceErr_NoError,
          let context, let serviceName, let regtype, let replyDomain else {
        return
    }
    let op = Unmanaged<DNSSDBrowseOperation>.fromOpaque(context).takeUnretainedValue()
    op.startResolve(
        flags: flags,
        interfaceIndex: interfaceIndex,
        name: String(cString: serviceName),
        regtype: String(cString: regtype),
        domain: String(cString: replyDomain),
        callback: deviceInfoResolveCallback
    )
}

private func rfbResolveCallback(
    _ sdRef: DNSServiceRef?,
    _ flags: DNSServiceFlags,
    _ interfaceIndex: UInt32,
    _ errorCode: DNSServiceErrorType,
    _ fullname: UnsafePointer<CChar>?,
    _ hosttarget: UnsafePointer<CChar>?,
    _ port: UInt16,
    _ txtLen: UInt16,
    _ txtRecord: UnsafePointer<UInt8>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let op = Unmanaged<DNSSDBrowseOperation>.fromOpaque(context).takeUnretainedValue()
    let resolvedFullname = errorCode == kDNSServiceErr_NoError ? fullname.map { String(cString: $0) } : nil
    let resolvedHost = errorCode == kDNSServiceErr_NoError ? hosttarget.map { String(cString: $0) } : nil
    op.handleRFBResolve(ref: sdRef, fullname: resolvedFullname, hosttarget: resolvedHost, port: port)
}

private func deviceInfoResolveCallback(
    _ sdRef: DNSServiceRef?,
    _ flags: DNSServiceFlags,
    _ interfaceIndex: UInt32,
    _ errorCode: DNSServiceErrorType,
    _ fullname: UnsafePointer<CChar>?,
    _ hosttarget: UnsafePointer<CChar>?,
    _ port: UInt16,
    _ txtLen: UInt16,
    _ txtRecord: UnsafePointer<UInt8>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let op = Unmanaged<DNSSDBrowseOperation>.fromOpaque(context).takeUnretainedValue()
    let resolvedFullname = errorCode == kDNSServiceErr_NoError ? fullname.map { String(cString: $0) } : nil
    op.handleDeviceInfoResolve(ref: sdRef, fullname: resolvedFullname, txtLen: txtLen, txtRecord: txtRecord)
}

/// Manages Bonjour discovery caching and background refreshes for the process.
/// Opening the list returns cached local hosts immediately (or waits briefly on
/// a cold start) and continues discovering in the background, notifying Prism
/// via `context.listChanged` when new Macs appear.
actor DiscoverySession {
    struct CachedDiscovery: Codable, Equatable {
        let hosts: [DiscoveredHost]
        let refreshedAt: Date
    }

    static let cacheFileName = "bonjour-cache.json"

    private let discovery: any BonjourDiscovering
    private let now: @Sendable () -> Date
    private let refreshInterval: TimeInterval
    private let coldStartWait: Duration
    private let scanDuration: Duration

    private var onlineHosts: [DiscoveredHost] = []
    private var cachedHosts: [DiscoveredHost] = []
    private var lastRefreshedAt: Date?
    private var loadedCacheFromDisk = false
    private var activeScan: Task<Void, Never>?
    /// Monotonic generation ID preventing late incremental updates from an older
    /// or cancelled scan from overwriting newer scan results.
    private var currentScanID: UInt64 = 0

    init(
        discovery: any BonjourDiscovering = DNSSDBonjourDiscovery(),
        now: @escaping @Sendable () -> Date = Date.init,
        refreshInterval: TimeInterval = 10,
        coldStartWait: Duration = .milliseconds(450),
        scanDuration: Duration = .seconds(2)
    ) {
        self.discovery = discovery
        self.now = now
        self.refreshInterval = refreshInterval
        self.coldStartWait = coldStartWait
        self.scanDuration = scanDuration
    }

    struct Snapshot: Sendable {
        let online: [DiscoveredHost]
        let cached: [DiscoveredHost]
        let refreshedAt: Date?
    }

    /// Reads the current in-memory (or disk-cached) hosts without starting a
    /// network scan. Used by actions like Connect and Pin so they never block.
    func cachedSnapshot(context: PrismContext) -> Snapshot {
        loadCacheIfNeeded(from: context.dataDirectory)
        return Snapshot(online: onlineHosts, cached: cachedHosts, refreshedAt: lastRefreshedAt)
    }

    /// Returns the best available local hosts right away, kicking off a
    /// background refresh when stale. On a cold start with no cached hosts,
    /// waits up to `coldStartWait` so nearby Macs appear on the first render.
    func snapshot(context: PrismContext) async -> Snapshot {
        loadCacheIfNeeded(from: context.dataDirectory)

        let isStale = lastRefreshedAt == nil
            || now().timeIntervalSince(lastRefreshedAt ?? .distantPast) >= refreshInterval

        let hadNoHosts = onlineHosts.isEmpty && cachedHosts.isEmpty

        if isStale && activeScan == nil {
            startBackgroundScan(context: context)
        }

        if hadNoHosts, activeScan != nil, coldStartWait > .zero {
            let step = Duration.milliseconds(40)
            var elapsed = Duration.zero
            while elapsed < coldStartWait {
                if !onlineHosts.isEmpty || activeScan == nil || Task.isCancelled {
                    break
                }
                try? await Task.sleep(for: step)
                elapsed += step
            }
        }

        return Snapshot(online: onlineHosts, cached: cachedHosts, refreshedAt: lastRefreshedAt)
    }

    /// Triggers an immediate rescan and waits briefly for initial responses.
    func forceRefresh(context: PrismContext) async {
        activeScan?.cancel()
        activeScan = nil
        startBackgroundScan(context: context)
        if coldStartWait > .zero {
            try? await Task.sleep(for: coldStartWait)
        }
    }

    /// Test seam: waits for any active background scan to complete.
    func waitForPendingScan() async {
        await activeScan?.value
    }

    private func loadCacheIfNeeded(from directory: URL?) {
        guard !loadedCacheFromDisk else { return }
        loadedCacheFromDisk = true
        if let disk = loadCache(from: directory) {
            cachedHosts = disk.hosts
            lastRefreshedAt = disk.refreshedAt
        }
    }

    private func startBackgroundScan(context: PrismContext) {
        currentScanID &+= 1
        let scanID = currentScanID
        let discovery = self.discovery
        let scanDuration = self.scanDuration
        let dataDirectory = context.dataDirectory

        activeScan = Task { [weak self] in
            let finalHosts = await discovery.discover(timeout: scanDuration) { [weak self] hosts in
                guard let self else { return }
                Task {
                    await self.applyIncremental(hosts, scanID: scanID, context: context, dataDirectory: dataDirectory)
                }
            }
            guard !Task.isCancelled, let self else { return }
            await self.finishScan(finalHosts, scanID: scanID, context: context, dataDirectory: dataDirectory)
        }
    }

    private func applyIncremental(
        _ hosts: [DiscoveredHost],
        scanID: UInt64,
        context: PrismContext,
        dataDirectory: URL?
    ) async {
        guard scanID == currentScanID, activeScan != nil, hosts != onlineHosts else { return }
        onlineHosts = hosts
        if !hosts.isEmpty {
            let refreshedAt = now()
            cachedHosts = hosts
            lastRefreshedAt = refreshedAt
            saveCache(CachedDiscovery(hosts: hosts, refreshedAt: refreshedAt), to: dataDirectory)
        }
        await context.listChanged(ScreenSharing.CommandID.connections)
    }

    private func finishScan(
        _ hosts: [DiscoveredHost],
        scanID: UInt64,
        context: PrismContext,
        dataDirectory: URL?
    ) {
        guard scanID == currentScanID else { return }
        let changed = hosts != onlineHosts || (hosts.isEmpty && !cachedHosts.isEmpty)
        onlineHosts = hosts
        let refreshedAt = now()
        lastRefreshedAt = refreshedAt
        // Replace cache with the completed scan so offline Macs don't linger forever.
        cachedHosts = hosts
        saveCache(CachedDiscovery(hosts: hosts, refreshedAt: refreshedAt), to: dataDirectory)
        activeScan = nil
        if changed {
            Task {
                await context.listChanged(ScreenSharing.CommandID.connections)
            }
        }
    }

    private func loadCache(from directory: URL?) -> CachedDiscovery? {
        guard let url = directory?.appendingPathComponent(Self.cacheFileName),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(CachedDiscovery.self, from: data)
    }

    private func saveCache(_ cache: CachedDiscovery, to directory: URL?) {
        guard let url = directory?.appendingPathComponent(Self.cacheFileName),
              let data = try? JSONEncoder().encode(cache) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
