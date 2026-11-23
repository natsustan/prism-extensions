import Foundation
import PrismExtensionProtocol
import PrismExtensionTesting
import Testing
@testable import Shottr

private actor FakeShottrOpener: ShottrOpening {
    let installed: Bool
    let error: (any Error)?
    private(set) var openedURLs: [URL] = []

    init(installed: Bool = true, error: (any Error)? = nil) {
        self.installed = installed
        self.error = error
    }

    nonisolated func isInstalled() -> Bool {
        installed
    }

    func open(_ url: URL) async throws {
        if let error {
            throw error
        }
        openedURLs.append(url)
    }
}

private struct OpenFailure: Error {}

@Suite("Shottr")
struct ShottrTests {
    @Test("List returns all 14 Shottr actions with expected URLs and interactive defaults")
    func listAllActions() async throws {
        let prism = try await PrismTestHost(Shottr(opener: FakeShottrOpener()))
        let list = try await prism.list(Shottr.CommandID.actions)

        #expect(list.filtering == .prism)
        #expect(list.items.count == 14)
        #expect(list.filters.map(\.id) == [Shottr.FilterID.capture, Shottr.FilterID.tools])

        let area = try #require(list.items.first { $0.id == ShottrAction.area.rawValue })
        #expect(area.section == "Capture")
        #expect(area.actions.first?.kind == .open(url: URL(string: "shottr://grab/area")!))
        #expect(area.actions.first?.interactive == true)

        let reverse = try #require(list.items.first { $0.id == ShottrAction.scrollingReverse.rawValue })
        #expect(reverse.actions.first?.kind == .open(url: URL(string: "shottr://grab/scrolling/reverse")!))
        #expect(reverse.actions.first?.interactive == true)

        let settings = try #require(list.items.first { $0.id == ShottrAction.settings.rawValue })
        #expect(settings.section == "Shottr")
        #expect(settings.actions.first?.kind == .open(url: URL(string: "shottr://settings")!))
        #expect(settings.actions.first?.interactive == false)
    }

    @Test("Filters narrow the list to Capture or Tools")
    func listFilters() async throws {
        let prism = try await PrismTestHost(Shottr(opener: FakeShottrOpener()))

        let capture = try await prism.list(Shottr.CommandID.actions, filter: Shottr.FilterID.capture)
        #expect(capture.items.count == 8)
        #expect(capture.items.allSatisfy { $0.section == "Capture" })

        let tools = try await prism.list(Shottr.CommandID.actions, filter: Shottr.FilterID.tools)
        #expect(tools.items.count == 6)
        #expect(tools.items.allSatisfy { $0.section == "Tools" || $0.section == "Shottr" })
    }

    @Test("Capture rows expose post-capture submenu, non-closing fallback, and Copy URL")
    func captureSecondaryActions() async throws {
        let prism = try await PrismTestHost(Shottr(opener: FakeShottrOpener()))
        let list = try await prism.list(Shottr.CommandID.actions)

        let area = try #require(list.items.first { $0.id == ShottrAction.area.rawValue })
        let thenMenu = try #require(area.actions.first { $0.id == Shottr.ActionID.thenMenu })
        #expect(thenMenu.actions.count == 5)
        let pin = try #require(thenMenu.actions.first { $0.id == "\(Shottr.ActionID.thenPrefix)pin" })
        #expect(pin.kind == .open(url: URL(string: "shottr://grab/area?then=pin")!))
        #expect(pin.interactive == true)

        let keepOpen = try #require(area.actions.first { $0.id == Shottr.ActionID.runKeepingPrism })
        #expect(keepOpen.interactive == false)

        let copy = try #require(area.actions.first { $0.id == Shottr.ActionID.copyURL })
        #expect(copy.kind == .copy(text: "shottr://grab/area"))
    }

    @Test("closeBeforeCapture preference disables interactive closing on list actions")
    func closeBeforeCapturePreference() async throws {
        let prism = try await PrismTestHost(
            Shottr(opener: FakeShottrOpener()),
            preferences: [Shottr.PreferenceID.closeBeforeCapture: .bool(false)]
        )
        let list = try await prism.list(Shottr.CommandID.actions)

        let area = try #require(list.items.first { $0.id == ShottrAction.area.rawValue })
        #expect(area.actions.first?.interactive == false)
        #expect(area.actions.contains { $0.id == Shottr.ActionID.runKeepingPrism } == false)
    }

    @Test("delaySeconds preference updates delayed capture URL, subtitle, and Delay submenu")
    func delayPreference() async throws {
        let prism = try await PrismTestHost(
            Shottr(opener: FakeShottrOpener()),
            preferences: [Shottr.PreferenceID.delaySeconds: .string("7")]
        )
        let list = try await prism.list(Shottr.CommandID.actions)

        let delayed = try #require(list.items.first { $0.id == ShottrAction.delayed.rawValue })
        #expect(delayed.subtitle == "Wait 7 seconds before capturing")
        #expect(delayed.accessories.first?.text == "7s")
        #expect(delayed.actions.first?.kind == .open(url: URL(string: "shottr://grab/delayed=7")!))

        let delayMenu = try #require(delayed.actions.first { $0.id == Shottr.ActionID.delayMenu })
        #expect(delayMenu.actions.map(\.kind) == [
            .open(url: URL(string: "shottr://grab/delayed=3")!),
            .open(url: URL(string: "shottr://grab/delayed=5")!),
            .open(url: URL(string: "shottr://grab/delayed=10")!),
        ])

        try await prism.setPreferences([Shottr.PreferenceID.delaySeconds: .string("1")])
        let oneSecond = try await prism.list(Shottr.CommandID.actions)
        let oneSecondDelayed = try #require(oneSecond.items.first { $0.id == ShottrAction.delayed.rawValue })
        #expect(oneSecondDelayed.subtitle == "Wait 1 second before capturing")
        #expect(oneSecondDelayed.actions.first?.kind == .open(url: URL(string: "shottr://grab/delayed=1")!))

        try await prism.setPreferences([Shottr.PreferenceID.delaySeconds: .string("invalid")])
        let fallback = try await prism.list(Shottr.CommandID.actions)
        let fallbackDelayed = try #require(fallback.items.first { $0.id == ShottrAction.delayed.rawValue })
        #expect(fallbackDelayed.actions.first?.kind == .open(url: URL(string: "shottr://grab/delayed")!))
    }

    @Test("Not installed state offers a download row instead of broken links")
    func notInstalledList() async throws {
        let prism = try await PrismTestHost(Shottr(opener: FakeShottrOpener(installed: false)))
        let list = try await prism.list(Shottr.CommandID.actions)

        #expect(list.items.count == 1)
        #expect(list.items.first?.id == "install-shottr")
        #expect(list.items.first?.actions.first?.kind == .open(url: WorkspaceShottrOpener.downloadURL))
    }

    @Test("Direct no-view commands open the matching shottr:// URL")
    func directCommands() async throws {
        let opener = FakeShottrOpener()
        let prism = try await PrismTestHost(Shottr(opener: opener))

        let expected: [(String, String)] = [
            (Shottr.CommandID.captureArea, "shottr://grab/area"),
            (Shottr.CommandID.captureFullscreen, "shottr://grab/fullscreen"),
            (Shottr.CommandID.captureWindow, "shottr://grab/window"),
            (Shottr.CommandID.captureScrolling, "shottr://grab/scrolling"),
            (Shottr.CommandID.captureOCR, "shottr://ocr"),
        ]

        for (command, _) in expected {
            let result = try await prism.run(command)
            #expect(result == .done)
        }

        let opened = await opener.openedURLs.map(\.absoluteString)
        #expect(opened == expected.map(\.1))
    }

    @Test("Direct commands fail cleanly when Shottr is missing or URL opening fails")
    func directCommandErrors() async throws {
        let missing = try await PrismTestHost(Shottr(opener: FakeShottrOpener(installed: false)))
        let missingResult = try await missing.run(Shottr.CommandID.captureArea)
        #expect(missingResult == .failed(message: "Shottr isn’t installed. Download it from shottr.cc."))

        let failing = try await PrismTestHost(Shottr(opener: FakeShottrOpener(error: OpenFailure())))
        let failingResult = try await failing.run(Shottr.CommandID.captureOCR)
        #expect(failingResult == .failed(message: "Could not open Shottr. Make sure URL Schema API is enabled in Shottr Settings → Advanced."))
    }

    @Test("Simplified Chinese localization translates list titles, sections, and filters")
    func chineseLocalization() async throws {
        let prism = try await PrismTestHost(Shottr(opener: FakeShottrOpener()), language: "zh-Hans")
        let list = try await prism.list(Shottr.CommandID.actions)

        #expect(list.searchPlaceholder == "搜索 Shottr 操作…")
        #expect(list.filters.map(\.title) == ["截图", "工具"])
        let area = try #require(list.items.first { $0.id == ShottrAction.area.rawValue })
        #expect(area.title == "区域截图")
        #expect(area.section == "截图")
    }
}
