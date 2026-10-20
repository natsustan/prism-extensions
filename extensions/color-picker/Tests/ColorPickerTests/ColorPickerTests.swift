import Foundation
import PrismExtensionKit
import PrismExtensionTesting
import Testing
@testable import ColorPicker

/// Hands out the colors a test queues, then nil, as when the user presses Escape.
actor FakeSampler: ColorSampling {
    private var colors: [RGBColor?]

    init(_ colors: [RGBColor?]) { self.colors = colors }

    func sample() -> RGBColor? {
        colors.isEmpty ? nil : colors.removeFirst()
    }
}

actor FakeClipboard: Clipboard {
    private(set) var copied: [String] = []

    func copy(_ text: String) { copied.append(text) }
}

/// Fixed seconds since 1970; dates are only compared, never shown.
let referenceDate = Date(timeIntervalSince1970: 1_760_000_000)

func makeHost(
    picking colors: [RGBColor?] = [],
    clipboard: FakeClipboard = FakeClipboard(),
    preferences: [String: ExtensionValue] = [:],
    state: [String: ExtensionValue] = [:]
) async throws -> PrismTestHost {
    try await PrismTestHost(
        ColorPicker(sampler: FakeSampler(colors), clipboard: clipboard, now: { referenceDate }),
        extensionID: "prism.color-picker",
        preferences: preferences,
        state: state
    )
}

func hex(_ value: String) -> RGBColor { RGBColor(hex: value)! }

@Suite("Color Picker")
struct ColorPickerTests {
    typealias CommandID = ColorPicker.CommandID
    typealias ActionID = ColorPicker.ActionID

    // MARK: - Pick Color

    @Test("picking copies the color as HEX, saves it, and reloads Colors")
    func picks() async throws {
        let clipboard = FakeClipboard()
        let prism = try await makeHost(picking: [hex("#FF6363")], clipboard: clipboard)

        #expect(try await prism.run(CommandID.pick) == .hud(message: "Copied #FF6363"))
        #expect(await clipboard.copied == ["#FF6363"])
        #expect(await prism.changedLists == [CommandID.colors])
        let list = try await prism.list(CommandID.colors)
        #expect(list.items.map(\.id) == ["FF6363"])
        #expect(list.items[0].icon == .swatch("#FF6363"))
    }

    @Test("pressing Escape in the loupe saves and copies nothing")
    func cancels() async throws {
        let clipboard = FakeClipboard()
        let prism = try await makeHost(picking: [nil], clipboard: clipboard)

        #expect(try await prism.run(CommandID.pick) == .done)
        #expect(await clipboard.copied.isEmpty)
        #expect(await prism.state.isEmpty)
    }

    @Test("picking copies the first format that is on")
    func copiesFirstFormat() async throws {
        let clipboard = FakeClipboard()
        let prism = try await makeHost(
            picking: [hex("#FF6363")], clipboard: clipboard,
            preferences: [ColorPicker.PreferenceID.formats: .strings(["-hex", "swiftui", "rgb"])]
        )

        _ = try await prism.run(CommandID.pick)
        #expect(await clipboard.copied == ["Color(red: 1, green: 0.388, blue: 0.388)"])
        let item = try #require(try await prism.list(CommandID.colors).items.first)
        #expect(item.title == "Color(red: 1, green: 0.388, blue: 0.388)")
        #expect(item.actions.map(\.id) == ["copy-swiftui", "copy-rgb", "copy-hsl", "copy-oklch",
                                           ActionID.favorite, ActionID.delete, ActionID.clearRecent])
    }

    @Test("with every format off, picking copies HEX")
    func fallsBackToHex() async throws {
        let clipboard = FakeClipboard()
        let off = ColorFormat.allCases.map { "-\($0.rawValue)" }
        let prism = try await makeHost(
            picking: [hex("#FF6363")], clipboard: clipboard,
            preferences: [ColorPicker.PreferenceID.formats: .strings(off)]
        )

        _ = try await prism.run(CommandID.pick)
        #expect(await clipboard.copied == ["#FF6363"])
    }

    @Test("picking a color again moves it to the top and keeps it a favorite")
    func repicks() async throws {
        let prism = try await makeHost(picking: [hex("#FF6363"), hex("#00FF00"), hex("#FF6363")])
        _ = try await prism.run(CommandID.pick)
        _ = try await prism.perform(ActionID.favorite, on: "FF6363", in: CommandID.colors)
        _ = try await prism.run(CommandID.pick)
        _ = try await prism.run(CommandID.pick)

        let list = try await prism.list(CommandID.colors)
        #expect(list.items.map(\.id) == ["FF6363", "00FF00"])
        #expect(list.items.map(\.section) == ["Favorites", "Recent"])
    }

    @Test("saved colors survive the extension stopping")
    func survivesRestart() async throws {
        let prism = try await makeHost(picking: [hex("#336699")])
        _ = try await prism.run(CommandID.pick)
        try await prism.restart(with: ColorPicker(sampler: FakeSampler([]), clipboard: FakeClipboard(), now: { referenceDate }))

        #expect(try await prism.list(CommandID.colors).items.map(\.id) == ["336699"])
    }

    @Test("wide-gamut colors that clamp to the same HEX stay apart and aren't named exactly")
    func wideGamut() async throws {
        let red = RGBColor(displayP3Red: 1, green: 0, blue: 0)
        let darker = RGBColor(displayP3Red: 0.97, green: 0, blue: 0)
        #expect(red.hex == darker.hex)
        let prism = try await makeHost(picking: [hex("#FF0000"), red, darker])
        for _ in 0..<3 { _ = try await prism.run(CommandID.pick) }

        let items = try await prism.list(CommandID.colors).items
        #expect(items.map(\.id) == ["color(display-p3 0.97 0 0)", "color(display-p3 1 0 0)", "FF0000"])
        #expect(items.map(\.subtitle) == ["Close to Red", "Close to Red", "Red"])
    }

    // MARK: - Colors

    @Test("an empty Colors list says how to add one")
    func emptyColors() async throws {
        let prism = try await makeHost()

        let list = try await prism.list(CommandID.colors)
        #expect(list.items.isEmpty)
        #expect(list.emptyMessage?.title == "No Colors")
        #expect(list.filters.map(\.id) == [ColorPicker.FilterID.favorites])
        let favorites = try await prism.list(CommandID.colors, filter: ColorPicker.FilterID.favorites)
        #expect(favorites.emptyMessage?.title == "No Favorites")
    }

    @Test("a saved color shows its name, every format in the detail, and copies on Return")
    func savedRow() async throws {
        let prism = try await makeHost(picking: [hex("#FF7F50")])
        _ = try await prism.run(CommandID.pick)

        let item = try #require(try await prism.list(CommandID.colors).items.first)
        #expect(item.title == "#FF7F50")
        #expect(item.subtitle == "Coral")
        #expect(item.keywords.contains("rgb(255 127 80)"))
        #expect(item.actions.first?.kind == .copy(text: "#FF7F50"))
        let detail = try #require(item.detail)
        #expect(detail.icon == .swatch("#FF7F50"))
        #expect(detail.sections.first?.rows.map(\.label) == ColorFormat.allCases.map(\.title))
        #expect(detail.metadata.first?.date == referenceDate)
    }

    @Test("favorites come first and have their own filter")
    func favorites() async throws {
        let prism = try await makeHost(picking: [hex("#111111"), hex("#222222"), hex("#333333")])
        for _ in 0..<3 { _ = try await prism.run(CommandID.pick) }

        let result = try await prism.perform(ActionID.favorite, on: "111111", in: CommandID.colors)
        #expect(result.reload)
        #expect(try await prism.list(CommandID.colors).items.map(\.id) == ["111111", "333333", "222222"])
        let favorites = try await prism.list(CommandID.colors, filter: ColorPicker.FilterID.favorites)
        #expect(favorites.items.map(\.id) == ["111111"])
        #expect(favorites.items[0].actions.contains { $0.id == ActionID.unfavorite })

        _ = try await prism.perform(ActionID.unfavorite, on: "111111", in: CommandID.colors)
        #expect(try await prism.list(CommandID.colors, filter: ColorPicker.FilterID.favorites).items.isEmpty)
    }

    @Test("deleting removes one color; clearing keeps favorites")
    func deletes() async throws {
        let prism = try await makeHost(picking: [hex("#111111"), hex("#222222"), hex("#333333")])
        for _ in 0..<3 { _ = try await prism.run(CommandID.pick) }
        _ = try await prism.perform(ActionID.favorite, on: "222222", in: CommandID.colors)

        _ = try await prism.perform(ActionID.delete, on: "333333", in: CommandID.colors)
        #expect(try await prism.list(CommandID.colors).items.map(\.id) == ["222222", "111111"])
        _ = try await prism.perform(ActionID.clearRecent, on: "111111", in: CommandID.colors)
        #expect(try await prism.list(CommandID.colors).items.map(\.id) == ["222222"])
    }

    @Test("old recent colors drop off, favorites never do")
    func recentLimit() {
        var saved = SavedColors()
        saved.add(hex("#000001"), at: referenceDate)
        saved.setFavorite(true, id: "000001")
        for index in 2...(SavedColors.recentLimit + 10) {
            saved.add(hex(String(format: "#%06X", index)), at: referenceDate)
        }
        #expect(saved.colors.count == SavedColors.recentLimit + 1)
        #expect(saved.favorites.map(\.id) == ["000001"])
        #expect(saved.colors.first?.id == String(format: "%06X", SavedColors.recentLimit + 10))
    }

    @Test("unreadable saved colors start empty and say why in the log")
    func unreadableState() async throws {
        let prism = try await makeHost(state: [SavedColors.stateKey: .string("not json")])

        #expect(try await prism.list(CommandID.colors).items.isEmpty)
        #expect(await prism.logs.contains { $0.hasPrefix("Saved colors could not be read") })
    }

    // MARK: - Convert Color

    @Test("Convert Color asks for a color until one is typed")
    func convertEmpty() async throws {
        let prism = try await makeHost()

        let list = try await prism.list(CommandID.convert)
        #expect(list.items.isEmpty)
        #expect(list.filtering == .extension)
        #expect(list.emptyMessage?.title == "Type a Color")
        #expect(try await prism.list(CommandID.convert, query: "zzz").emptyMessage?.title == "Not a Color")
    }

    @Test("a typed color shows every format, those that are on first")
    func convertsColor() async throws {
        let prism = try await makeHost(preferences: [ColorPicker.PreferenceID.formats: .strings(["oklch", "-hex"])])

        let list = try await prism.list(CommandID.convert, query: "rgb(255 99 99)")
        #expect(list.items.map(\.subtitle) == ["OKLCH", "RGB", "HSL", "HEX", "LCH", "Display P3", "SwiftUI"])
        #expect(list.items.map(\.section).allSatisfy { $0 == "Close to Tomato" })
        let hexRow = list.items[3]
        #expect(hexRow.title == "#FF6363")
        #expect(hexRow.actions.first?.kind == .copy(text: "#FF6363"))
    }

    @Test("a name finds the named colors, and an exact name also converts")
    func convertsNames() async throws {
        let prism = try await makeHost()

        let coral = try await prism.list(CommandID.convert, query: "coral")
        #expect(coral.items.first?.title == "#FF7F50")
        #expect(coral.items.filter { $0.section == "Named Colors" }.map(\.title) == ["Coral", "Light Coral"])
        let slate = try await prism.list(CommandID.convert, query: "slate")
        #expect(slate.items.allSatisfy { $0.section == "Named Colors" })
        #expect(slate.items.first?.actions.map(\.id).contains(ActionID.copyName) == true)
    }

    @Test("saving a converted color adds it to Colors at full precision")
    func savesConverted() async throws {
        let prism = try await makeHost()
        let list = try await prism.list(CommandID.convert, query: "color(display-p3 1 0 0)")
        let row = try #require(list.items.first)

        let result = try await prism.perform(ActionID.save, on: row.id, in: CommandID.convert)
        #expect(result.result == .keepOpen(message: "Saved #FF0000 to Colors."))
        #expect(await prism.changedLists == [CommandID.colors])
        let saved = try #require(try await prism.list(CommandID.colors).items.first)
        let p3Row = saved.detail?.sections.first?.rows.first { $0.label == "Display P3" }
        #expect(p3Row?.value == "color(display-p3 1 0 0)")

        let named = try #require(try await prism.list(CommandID.convert, query: "navy").items.last)
        _ = try await prism.perform(ActionID.save, on: named.id, in: CommandID.convert)
        #expect(try await prism.list(CommandID.colors).items.map(\.id) == ["000080", "color(display-p3 1 0 0)"])
    }

    // MARK: - Preferences

    @Test("Formats lists every format with the common ones on")
    func formatPreference() async throws {
        let prism = try await makeHost()

        let items = try await prism.preferenceItems(ColorPicker.PreferenceID.formats)
        #expect(items.map(\.title) == ["HEX", "RGB", "HSL", "OKLCH", "LCH", "Display P3", "SwiftUI"])
        #expect(items.map(\.isOn) == [true, true, true, true, false, false, false])
    }
}
