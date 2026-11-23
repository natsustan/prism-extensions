import Foundation
import PrismExtensionKit

/// Triggers Shottr captures, OCR, and tools through Shottr's URL Scheme API.
/// `actions` sets `searchesApp` to `cc.ffitch.shottr` so pressing Tab on
/// Shottr's row in root search opens all Shottr actions in place.
@main
struct Shottr: PrismExtension {
    enum CommandID {
        static let actions = "actions"
        static let captureArea = "capture-area"
        static let captureFullscreen = "capture-fullscreen"
        static let captureWindow = "capture-window"
        static let captureScrolling = "capture-scrolling"
        static let captureOCR = "capture-ocr"
    }

    enum ActionID {
        static let run = "run"
        static let runKeepingPrism = "run-keeping-prism"
        static let delayMenu = "delay-menu"
        static let delayPrefix = "delay-"
        static let thenMenu = "then-menu"
        static let thenPrefix = "then-"
        static let copyURL = "copy-url"
        static let download = "download"
    }

    enum FilterID {
        static let capture = "capture"
        static let tools = "tools"
    }

    enum PreferenceID {
        static let closeBeforeCapture = "closeBeforeCapture"
        static let delaySeconds = "delaySeconds"
    }

    let opener: any ShottrOpening

    init() {
        self.init(opener: WorkspaceShottrOpener())
    }

    init(opener: any ShottrOpening) {
        self.opener = opener
    }

    func run(command: String, context: PrismContext) async throws -> ExtensionCommandResult {
        guard let action = Self.directAction(for: command) else {
            throw PrismExtensionError(localized("Shottr has no command “\(command)”."))
        }
        guard opener.isInstalled() else {
            return .failed(message: localized("Shottr isn’t installed. Download it from shottr.cc."))
        }
        do {
            try await opener.open(action.url())
            return .done
        } catch {
            return .failed(message: localized("Could not open Shottr. Make sure URL Schema API is enabled in Shottr Settings → Advanced."))
        }
    }

    func list(command: String, query: String, filter: String?, context: PrismContext) async throws -> ExtensionList {
        guard command == CommandID.actions else {
            throw PrismExtensionError(localized("Shottr has no list “\(command)”."))
        }
        guard opener.isInstalled() else {
            return ExtensionList(
                items: [ShottrRows.notInstalledItem()],
                filtering: .prism,
                searchPlaceholder: localized("Search Shottr actions…"),
                filters: ShottrRows.filters,
                emptyMessage: ExtensionListMessage(
                    title: localized("Shottr Not Installed"),
                    message: localized("Download Shottr from shottr.cc and enable URL Schema API in Settings → Advanced."),
                    symbol: "camera.viewfinder"
                )
            )
        }
        let closeBeforeCapture = context.preferences.bool(PreferenceID.closeBeforeCapture, default: true)
        let delaySeconds = ShottrAction.parseDelay(context.preferences.string(PreferenceID.delaySeconds))
        return ExtensionList(
            items: ShottrRows.items(
                filter: filter,
                closeBeforeCapture: closeBeforeCapture,
                delaySeconds: delaySeconds
            ),
            filtering: .prism,
            searchPlaceholder: localized("Search Shottr actions…"),
            filters: ShottrRows.filters,
            emptyMessage: ExtensionListMessage(
                title: localized("No Matching Actions"),
                message: localized("Try another search term or clear the filter."),
                symbol: "camera.viewfinder"
            )
        )
    }

    private static func directAction(for command: String) -> ShottrAction? {
        switch command {
        case CommandID.captureArea: .area
        case CommandID.captureFullscreen: .fullscreen
        case CommandID.captureWindow: .window
        case CommandID.captureScrolling: .scrolling
        case CommandID.captureOCR: .ocr
        default: nil
        }
    }
}
