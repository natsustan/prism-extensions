import Foundation

/// Reads what people type or paste as a color: HEX, CSS `rgb()`, `hsl()`,
/// `oklch()`, `lch()`, `color(display-p3 …)` in modern or comma syntax, or a
/// CSS color name.
enum ColorParser {
    static func parse(_ text: String) -> RGBColor? {
        // Huge values overflow the conversions to infinity or NaN, which no
        // format can write; far past any real gamut, they are not colors.
        guard let color = read(text), [color.red, color.green, color.blue].allSatisfy({ abs($0) <= 100 }) else {
            return nil
        }
        return color
    }

    private static func read(_ text: String) -> RGBColor? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ";")))
            .lowercased()
        guard !text.isEmpty else { return nil }
        if let color = RGBColor(hex: text) { return color }
        if let color = ColorNames.color(named: text) { return color }
        guard let open = text.firstIndex(of: "("), text.hasSuffix(")") else { return nil }
        let function = text[..<open].trimmingCharacters(in: .whitespaces)
        var arguments = arguments(String(text[text.index(after: open)..<text.index(before: text.endIndex)]))
        switch function {
        case "rgb", "rgba":
            guard [3, 4].contains(arguments.count),
                  let red = channel(arguments[0]), let green = channel(arguments[1]), let blue = channel(arguments[2]),
                  let alpha = alpha(arguments, at: 3) else { return nil }
            return RGBColor(red: red, green: green, blue: blue, alpha: alpha)
        case "hsl", "hsla":
            guard [3, 4].contains(arguments.count), let hue = angle(arguments[0]),
                  let saturation = percentage(arguments[1]), let lightness = percentage(arguments[2]),
                  let alpha = alpha(arguments, at: 3) else { return nil }
            return RGBColor(hue: hue, saturation: saturation, lightness: lightness, alpha: alpha)
        case "oklch":
            guard [3, 4].contains(arguments.count), let lightness = fraction(arguments[0]),
                  let chroma = number(arguments[1], percentOf: 0.4), let hue = angle(arguments[2]),
                  let alpha = alpha(arguments, at: 3) else { return nil }
            return RGBColor(oklchLightness: lightness, chroma: chroma, hue: hue, alpha: alpha)
        case "lch":
            guard [3, 4].contains(arguments.count), let lightness = number(arguments[0], percentOf: 100),
                  let chroma = number(arguments[1], percentOf: 150), let hue = angle(arguments[2]),
                  let alpha = alpha(arguments, at: 3) else { return nil }
            return RGBColor(lchLightness: lightness, chroma: chroma, hue: hue, alpha: alpha)
        case "color":
            guard arguments.first == "display-p3" else { return nil }
            arguments.removeFirst()
            guard [3, 4].contains(arguments.count), let red = fraction(arguments[0]),
                  let green = fraction(arguments[1]), let blue = fraction(arguments[2]),
                  let alpha = alpha(arguments, at: 3) else { return nil }
            return RGBColor(displayP3Red: red, green: green, blue: blue, alpha: alpha)
        default:
            return nil
        }
    }

    /// Commas, slashes, and spaces all separate arguments.
    private static func arguments(_ text: String) -> [String] {
        text.split { $0 == "," || $0 == "/" || $0.isWhitespace }.map(String.init)
    }

    /// 0...255, or a percentage; CSS clamps `rgb()` to that range rather
    /// than reading it as a wide-gamut color.
    private static func channel(_ token: String) -> Double? {
        number(token, percentOf: 255).map { min(max($0 / 255, 0), 1) }
    }

    /// A number, or a percentage of `whole`.
    private static func number(_ token: String, percentOf whole: Double) -> Double? {
        if token.hasSuffix("%") { return finite(token.dropLast()).map { $0 / 100 * whole } }
        return finite(token)
    }

    /// `Double` also reads “nan”, “inf”, and “1e400”.
    private static func finite(_ token: some StringProtocol) -> Double? {
        Double(String(token)).flatMap { $0.isFinite ? $0 : nil }
    }

    /// 0...1, or a percentage.
    private static func fraction(_ token: String) -> Double? {
        number(token, percentOf: 1)
    }

    /// A percentage, or a bare number read as one (`hsl(0 100 50)`).
    private static func percentage(_ token: String) -> Double? {
        finite(token.hasSuffix("%") ? token.dropLast() : Substring(token)).map { $0 / 100 }
    }

    private static func angle(_ token: String) -> Double? {
        finite(token.hasSuffix("deg") ? token.dropLast(3) : Substring(token))
    }

    /// Clamped to 0...1, as CSS does.
    private static func alpha(_ arguments: [String], at index: Int) -> Double? {
        arguments.indices.contains(index) ? fraction(arguments[index]).map { min(max($0, 0), 1) } : 1
    }
}
