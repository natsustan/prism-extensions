import Testing
@testable import ColorPicker

@Suite("Color conversion")
struct ColorConversionTests {
    let coralRed = RGBColor(hex: "#FF6363")!
    let red = RGBColor(red: 1, green: 0, blue: 0)

    @Test("formats write CSS and SwiftUI the same in every locale")
    func formats() {
        #expect(ColorFormat.hex.string(for: coralRed) == "#FF6363")
        #expect(ColorFormat.rgb.string(for: coralRed) == "rgb(255 99 99)")
        #expect(ColorFormat.hsl.string(for: coralRed) == "hsl(0 100% 69.4%)")
        #expect(ColorFormat.swiftUI.string(for: coralRed) == "Color(red: 1, green: 0.388, blue: 0.388)")
        #expect(ColorFormat.oklch.string(for: red) == "oklch(0.628 0.2577 29.23)")
        // CSS Color 4's lch(54.29 106.84 40.85), within its matrices' rounding.
        let lch = red.lch
        #expect(abs(lch.lightness - 54.29) < 0.01 && abs(lch.chroma - 106.84) < 0.01 && abs(lch.hue - 40.85) < 0.01)
        #expect(ColorFormat.displayP3.string(for: red) == "color(display-p3 0.9175 0.2003 0.1386)")
    }

    @Test("a translucent color carries its alpha in every format")
    func alpha() {
        let translucent = RGBColor(hex: "#FF636380")!
        #expect(ColorFormat.hex.string(for: translucent) == "#FF636380")
        #expect(ColorFormat.rgb.string(for: translucent) == "rgb(255 99 99 / 0.5)")
        #expect(ColorFormat.hsl.string(for: translucent) == "hsl(0 100% 69.4% / 0.5)")
        #expect(ColorFormat.swiftUI.string(for: translucent) == "Color(red: 1, green: 0.388, blue: 0.388, opacity: 0.5)")
    }

    @Test("grays have no hue rather than a rounding artifact")
    func grays() {
        let gray = RGBColor(hex: "#808080")!
        #expect(ColorFormat.hsl.string(for: gray) == "hsl(0 0% 50.2%)")
        #expect(gray.oklch.hue == 0)
        #expect(gray.lch.hue == 0)
    }

    @Test("a color beyond sRGB keeps its Display P3 value and clamps in HEX")
    func wideGamut() {
        let p3Red = RGBColor(displayP3Red: 1, green: 0, blue: 0)
        #expect(p3Red.red > 1)
        #expect(p3Red.hex == "#FF0000")
        #expect(ColorFormat.displayP3.string(for: p3Red) == "color(display-p3 1 0 0)")
    }

    @Test("OKLCH, LCH, Display P3, and HSL read back to the same color")
    func roundTrips() {
        let oklch = coralRed.oklch
        #expect(RGBColor(oklchLightness: oklch.lightness, chroma: oklch.chroma, hue: oklch.hue).hex == "#FF6363")
        let lch = coralRed.lch
        #expect(RGBColor(lchLightness: lch.lightness, chroma: lch.chroma, hue: lch.hue).hex == "#FF6363")
        let p3 = coralRed.displayP3
        #expect(RGBColor(displayP3Red: p3.red, green: p3.green, blue: p3.blue).hex == "#FF6363")
        let hsl = coralRed.hsl
        #expect(RGBColor(hue: hsl.hue, saturation: hsl.saturation, lightness: hsl.lightness).hex == "#FF6363")
    }

    @Test("the parser reads HEX, CSS functions in either syntax, and names", arguments: [
        ("#f63", "#FF6633"),
        ("FF6363", "#FF6363"),
        ("#FF636380", "#FF636380"),
        ("rgb(255, 99, 99)", "#FF6363"),
        ("rgba(255,99,99,0.5)", "#FF636380"),
        ("rgb(100% 0% 0% / 50%)", "#FF000080"),
        ("hsl(0deg 100% 50%)", "#FF0000"),
        ("hsla(120, 100%, 25%, 1)", "#008000"),
        ("oklch(0.628 0.2577 29.23)", "#FF0000"),
        ("oklch(62.8% 0.2577 29.23)", "#FF0000"),
        ("lch(54.29 106.84 40.85)", "#FF0000"),
        ("lch(54.29% 71.23% 40.85deg / 0.5)", "#FF000080"),
        ("color(display-p3 0.9175 0.2003 0.1386)", "#FF0000"),
        ("  Coral; ", "#FF7F50"),
        ("light grey", "#D3D3D3"),
        ("RebeccaPurple", "#663399"),
    ])
    func parses(input: String, hex: String) {
        #expect(ColorParser.parse(input)?.hex == hex)
    }

    @Test("every format the extension writes reads back")
    func readsItsOwnFormats() {
        for format in ColorFormat.allCases where format != .swiftUI {
            #expect(ColorParser.parse(format.string(for: coralRed))?.hex == "#FF6363", "\(format)")
        }
    }

    @Test("rgb() clamps channels and alpha, as CSS does, rather than reading a wide-gamut color")
    func clampsRGB() {
        #expect(ColorParser.parse("rgb(300 -20 0 / 2)") == red)
        #expect(ColorParser.parse("rgb(1e300 0 0)") == red)
    }

    @Test("the parser rejects what isn't a color", arguments: [
        "", "hello", "#12345", "rgb(1 2)", "rgb(a b c)", "color(srgb 1 0 0)", "hsl(0 100%)", "rgb(1 2 3",
        "rgb(nan 0 0)", "rgb(0 0 0 / nan)", "hsl(inf 50% 50%)", "oklch(1e400 0 0)", "oklch(1e300 1e300 0)",
        "lch(1e300 0 0)", "color(display-p3 1e200 0 0)",
    ])
    func rejects(input: String) {
        #expect(ColorParser.parse(input) == nil)
    }

    @Test("a color is named exactly or by the closest CSS color")
    func names() {
        let coral = ColorNames.match(for: RGBColor(hex: "#FF7F50")!)
        #expect(coral.description == "Coral")
        let close = ColorNames.match(for: RGBColor(hex: "#FF6040")!)
        #expect(!close.isExact)
        #expect(close.description == "Close to Tomato")
        #expect(ColorNames.match(for: RGBColor(hex: "#FF7F5080")!).description == "Coral")
    }

    @Test("names are found by every word typed")
    func nameSearch() {
        #expect(ColorNames.search("coral").map(\.name) == ["Coral", "Light Coral"])
        #expect(ColorNames.search("slate blue").map(\.name) == ["Dark Slate Blue", "Medium Slate Blue", "Slate Blue"])
        #expect(ColorNames.search("lightgrey").map(\.name) == ["Light Gray"])
        #expect(ColorNames.search("  ").isEmpty)
        #expect(ColorNames.all.allSatisfy { ColorNames.color(named: $0.keyword) != nil })
    }
}
