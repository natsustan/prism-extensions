import AppKit
import Foundation

/// Talks to Launch Services for Shottr: checking whether the app is installed
/// and opening `shottr://` URLs without stealing focus (`activates = false`,
/// matching `open -g`).
protocol ShottrOpening: Sendable {
    func isInstalled() -> Bool
    func open(_ url: URL) async throws
}

struct WorkspaceShottrOpener: ShottrOpening {
    static let bundleID = "cc.ffitch.shottr"
    static let downloadURL = URL(string: "https://shottr.cc")!

    func isInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) != nil
    }

    func open(_ url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.open(url, configuration: configuration)
    }
}
