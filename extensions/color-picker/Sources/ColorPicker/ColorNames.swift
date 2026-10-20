import Foundation

/// The CSS named colors, for naming a color and finding one by name.
enum ColorNames {
    struct Named: Sendable {
        let name: String
        let color: RGBColor
        /// Worked out once: naming a list of colors compares each with every
        /// named color.
        let oklab: (l: Double, a: Double, b: Double)

        /// The CSS keyword: the name in lowercase without spaces.
        let keyword: String
    }

    /// A color's name: the exact one, or the closest.
    struct Match: Sendable {
        let name: String
        let isExact: Bool

        var description: String { isExact ? name : "Close to \(name)" }
    }

    static func match(for color: RGBColor) -> Match {
        var opaque = color
        opaque.alpha = 1
        let lab = opaque.oklab
        let closest = all.min { distance($0.oklab, lab) < distance($1.oklab, lab) }!
        return Match(name: closest.name, isExact: opaque.isInSRGB && closest.color.hex == opaque.hex)
    }

    /// The color a CSS keyword names.
    static func color(named keyword: String) -> RGBColor? {
        byKeyword[normalized(keyword)]
    }

    /// Named colors whose name contains every word of `query`.
    static func search(_ query: String) -> [Named] {
        let words = query.split(whereSeparator: \.isWhitespace).map { normalized(String($0)) }
        guard !words.isEmpty else { return [] }
        return all.filter { named in
            let name = named.name.lowercased()
            return words.allSatisfy { name.contains($0) || named.keyword.contains($0) }
        }
    }

    /// Squared perceptual distance in OKLab, enough to find the closest.
    private static func distance(_ x: (l: Double, a: Double, b: Double), _ y: (l: Double, a: Double, b: Double)) -> Double {
        (x.l - y.l) * (x.l - y.l) + (x.a - y.a) * (x.a - y.a) + (x.b - y.b) * (x.b - y.b)
    }

    /// Lowercase without spaces, accepting the British “grey”.
    private static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "grey", with: "gray")
    }

    private static let byKeyword = Dictionary(all.map { ($0.keyword, $0.color) }, uniquingKeysWith: { first, _ in first })

    static let all: [Named] = [
        ("Alice Blue", "F0F8FF"), ("Antique White", "FAEBD7"), ("Aqua", "00FFFF"), ("Aquamarine", "7FFFD4"),
        ("Azure", "F0FFFF"), ("Beige", "F5F5DC"), ("Bisque", "FFE4C4"), ("Black", "000000"),
        ("Blanched Almond", "FFEBCD"), ("Blue", "0000FF"), ("Blue Violet", "8A2BE2"), ("Brown", "A52A2A"),
        ("Burly Wood", "DEB887"), ("Cadet Blue", "5F9EA0"), ("Chartreuse", "7FFF00"), ("Chocolate", "D2691E"),
        ("Coral", "FF7F50"), ("Cornflower Blue", "6495ED"), ("Cornsilk", "FFF8DC"), ("Crimson", "DC143C"),
        ("Dark Blue", "00008B"), ("Dark Cyan", "008B8B"), ("Dark Goldenrod", "B8860B"),
        ("Dark Gray", "A9A9A9"), ("Dark Green", "006400"), ("Dark Khaki", "BDB76B"), ("Dark Magenta", "8B008B"),
        ("Dark Olive Green", "556B2F"), ("Dark Orange", "FF8C00"), ("Dark Orchid", "9932CC"), ("Dark Red", "8B0000"),
        ("Dark Salmon", "E9967A"), ("Dark Sea Green", "8FBC8F"), ("Dark Slate Blue", "483D8B"),
        ("Dark Slate Gray", "2F4F4F"), ("Dark Turquoise", "00CED1"), ("Dark Violet", "9400D3"),
        ("Deep Pink", "FF1493"), ("Deep Sky Blue", "00BFFF"), ("Dim Gray", "696969"), ("Dodger Blue", "1E90FF"),
        ("Firebrick", "B22222"), ("Floral White", "FFFAF0"), ("Forest Green", "228B22"), ("Fuchsia", "FF00FF"),
        ("Gainsboro", "DCDCDC"), ("Ghost White", "F8F8FF"), ("Gold", "FFD700"), ("Goldenrod", "DAA520"),
        ("Gray", "808080"), ("Green", "008000"), ("Green Yellow", "ADFF2F"), ("Honeydew", "F0FFF0"),
        ("Hot Pink", "FF69B4"), ("Indian Red", "CD5C5C"), ("Indigo", "4B0082"), ("Ivory", "FFFFF0"),
        ("Khaki", "F0E68C"), ("Lavender", "E6E6FA"), ("Lavender Blush", "FFF0F5"), ("Lawn Green", "7CFC00"),
        ("Lemon Chiffon", "FFFACD"), ("Light Blue", "ADD8E6"), ("Light Coral", "F08080"), ("Light Cyan", "E0FFFF"),
        ("Light Goldenrod Yellow", "FAFAD2"), ("Light Gray", "D3D3D3"), ("Light Green", "90EE90"),
        ("Light Pink", "FFB6C1"), ("Light Salmon", "FFA07A"), ("Light Sea Green", "20B2AA"),
        ("Light Sky Blue", "87CEFA"), ("Light Slate Gray", "778899"), ("Light Steel Blue", "B0C4DE"),
        ("Light Yellow", "FFFFE0"), ("Lime", "00FF00"), ("Lime Green", "32CD32"), ("Linen", "FAF0E6"),
        ("Maroon", "800000"), ("Medium Aquamarine", "66CDAA"), ("Medium Blue", "0000CD"),
        ("Medium Orchid", "BA55D3"), ("Medium Purple", "9370DB"), ("Medium Sea Green", "3CB371"),
        ("Medium Slate Blue", "7B68EE"), ("Medium Spring Green", "00FA9A"), ("Medium Turquoise", "48D1CC"),
        ("Medium Violet Red", "C71585"), ("Midnight Blue", "191970"), ("Mint Cream", "F5FFFA"),
        ("Misty Rose", "FFE4E1"), ("Moccasin", "FFE4B5"), ("Navajo White", "FFDEAD"), ("Navy", "000080"),
        ("Old Lace", "FDF5E6"), ("Olive", "808000"), ("Olive Drab", "6B8E23"), ("Orange", "FFA500"),
        ("Orange Red", "FF4500"), ("Orchid", "DA70D6"), ("Pale Goldenrod", "EEE8AA"), ("Pale Green", "98FB98"),
        ("Pale Turquoise", "AFEEEE"), ("Pale Violet Red", "DB7093"), ("Papaya Whip", "FFEFD5"),
        ("Peach Puff", "FFDAB9"), ("Peru", "CD853F"), ("Pink", "FFC0CB"), ("Plum", "DDA0DD"),
        ("Powder Blue", "B0E0E6"), ("Purple", "800080"), ("Rebecca Purple", "663399"), ("Red", "FF0000"),
        ("Rosy Brown", "BC8F8F"), ("Royal Blue", "4169E1"), ("Saddle Brown", "8B4513"), ("Salmon", "FA8072"),
        ("Sandy Brown", "F4A460"), ("Sea Green", "2E8B57"), ("Seashell", "FFF5EE"), ("Sienna", "A0522D"),
        ("Silver", "C0C0C0"), ("Sky Blue", "87CEEB"), ("Slate Blue", "6A5ACD"), ("Slate Gray", "708090"),
        ("Snow", "FFFAFA"), ("Spring Green", "00FF7F"), ("Steel Blue", "4682B4"), ("Tan", "D2B48C"),
        ("Teal", "008080"), ("Thistle", "D8BFD8"), ("Tomato", "FF6347"), ("Turquoise", "40E0D0"),
        ("Violet", "EE82EE"), ("Wheat", "F5DEB3"), ("White", "FFFFFF"), ("White Smoke", "F5F5F5"),
        ("Yellow", "FFFF00"), ("Yellow Green", "9ACD32"),
        // CSS aliases: same colors as Aqua and Fuchsia, kept so they are found by name.
        ("Cyan", "00FFFF"), ("Magenta", "FF00FF"),
    ].map { name, hex in
        let color = RGBColor(hex: hex)!
        return Named(name: name, color: color, oklab: color.oklab, keyword: normalized(name))
    }
}
