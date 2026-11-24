import AppKit
import Foundation

/// Opens Antigravity (or connects directly to a remote SSH host) and reveals
/// local project folders in Finder.
protocol AntigravityLaunching: Sendable {
    func openLocalApp(antigravityAppPath: String?) async throws
    func openRemoteSSHHost(_ host: String, antigravityAppPath: String?) async throws
    func revealInFinder(path: String) async throws
}

enum AntigravityLaunchError: Error, Equatable {
    case projectNotFound(String)
    case appNotFound(String?)
    case openFailed(String)
}

/// Production launcher backed by `NSWorkspace`.
struct WorkspaceAntigravityLauncher: AntigravityLaunching {
    func openLocalApp(antigravityAppPath: String?) async throws {
        let appURL = try resolveAppURL(preferredPath: antigravityAppPath)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        } catch {
            throw AntigravityLaunchError.openFailed(error.localizedDescription)
        }
    }

    func openRemoteSSHHost(_ host: String, antigravityAppPath: String?) async throws {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            throw AntigravityLaunchError.projectNotFound("")
        }
        let appURL = try resolveAppURL(preferredPath: antigravityAppPath)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        // Antigravity's single-instance Electron lock forwards `--ssh-host=`
        // through `second-instance` when already running and exits the helper
        // instance immediately; `createsNewApplicationInstance` ensures the
        // argument is delivered even when Antigravity is already open.
        config.createsNewApplicationInstance = true
        config.arguments = ["--ssh-host=\(trimmedHost)"]
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        } catch {
            throw AntigravityLaunchError.openFailed(error.localizedDescription)
        }
    }

    func revealInFinder(path: String) async throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw AntigravityLaunchError.projectNotFound(path)
        }
        let url = URL(fileURLWithPath: path)
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func resolveAppURL(preferredPath: String?) throws -> URL {
        if let raw = preferredPath?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else {
                throw AntigravityLaunchError.appNotFound(raw)
            }
            return URL(fileURLWithPath: expanded)
        }
        for channel in AntigravityChannel.allCases {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: channel.bundleIdentifier) {
                return url
            }
        }
        for channel in AntigravityChannel.allCases {
            if FileManager.default.fileExists(atPath: channel.defaultAppPath) {
                return URL(fileURLWithPath: channel.defaultAppPath)
            }
        }
        throw AntigravityLaunchError.appNotFound(nil)
    }
}
