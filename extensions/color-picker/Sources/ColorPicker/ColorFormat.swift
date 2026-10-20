import Foundation

/// The ways a color is written out. The raw values are preference item and
/// action IDs, so they never change.
enum ColorFormat: String, CaseIterable, Sendable {
    case hex
    case rgb
    case hsl
    case oklch
    case lch
    case displayP3 = "p3"
    case swiftUI = "swiftui"

    var title: String {
        switch self {
        case .hex: "HEX"
        case .rgb: "RGB"
        case .hsl: "HSL"
        case .oklch: "OKLCH"
        case .lch: "LCH"
        case .displayP3: "Display P3"
        case .swiftUI: "SwiftUI"
        }
    }

    /// On until the user changes the Formats preference.
    var isOnByDefault: Bool {
        switch self {
        case .hex, .rgb, .hsl, .oklch: true
        case .lch, .displayP3, .swiftUI: false
        }
    }

    func string(for color: RGBColor) -> String {
        let alpha = color.isOpaque ? "" : " / \(Self.number(color.alpha, digits: 2))"
        switch self {
        case .hex:
            return color.hex
        case .rgb:
            let bytes = color.bytes
            return "rgb(\(bytes.red) \(bytes.green) \(bytes.blue)\(alpha))"
        case .hsl:
            let hsl = color.hsl
            return "hsl(\(Self.number(hsl.hue, digits: 1)) \(Self.number(hsl.saturation * 100, digits: 1))% "
                + "\(Self.number(hsl.lightness * 100, digits: 1))%\(alpha))"
        case .oklch:
            let oklch = color.oklch
            return "oklch(\(Self.number(oklch.lightness, digits: 4)) \(Self.number(oklch.chroma, digits: 4)) "
                + "\(Self.number(oklch.hue, digits: 2))\(alpha))"
        case .lch:
            let lch = color.lch
            return "lch(\(Self.number(lch.lightness, digits: 2)) \(Self.number(lch.chroma, digits: 2)) "
                + "\(Self.number(lch.hue, digits: 2))\(alpha))"
        case .displayP3:
            let p3 = color.displayP3
            return "color(display-p3 \(Self.number(p3.red, digits: 4)) \(Self.number(p3.green, digits: 4)) "
                + "\(Self.number(p3.blue, digits: 4))\(alpha))"
        case .swiftUI:
            let opacity = color.isOpaque ? "" : ", opacity: \(Self.number(color.alpha, digits: 2))"
            return "Color(red: \(Self.number(color.red, digits: 3)), green: \(Self.number(color.green, digits: 3)), "
                + "blue: \(Self.number(color.blue, digits: 3))\(opacity))"
        }
    }

    /// At most `digits` decimals, without trailing zeros, the same in every
    /// locale (`String(format:)` always writes a period).
    static func number(_ value: Double, digits: Int) -> String {
        var text = String(format: "%.\(digits)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }
}
