import Foundation

/// A number typed with Arabic digits, kept as its digits rather than a
/// `Double` so 0.1 and sixteen-digit amounts convert exactly.
struct ArabicNumber: Equatable, Sendable {
    /// Integers up to 9999万亿, the largest the 万/亿 units can say without
    /// stacking 亿亿.
    static let limit: UInt64 = 10_000_000_000_000_000

    enum ParseError: Error, Equatable {
        case notANumber
        case tooLarge
    }

    var isNegative: Bool
    var integer: UInt64
    /// The digits after the point, as typed ("50" stays "50").
    var fraction: String

    init(isNegative: Bool = false, integer: UInt64, fraction: String = "") {
        self.isNegative = isNegative
        self.integer = integer
        self.fraction = fraction
    }

    var isZero: Bool { integer == 0 && fraction.allSatisfy { $0 == "0" } }

    /// Reads what people paste: thousands separators and spaces before the
    /// point, a ¥ sign, full-width digits, and a leading minus, either side
    /// of the ¥ (`-¥1,234.00`).
    init(parsing input: String) throws(ParseError) {
        var text = Substring(String(input.map(Self.halfWidth)).trimmingCharacters(in: .whitespaces))
        if text.first == "¥" { text.removeFirst() }
        var negative = false
        if let sign = text.first, sign == "-" || sign == "+" {
            negative = sign == "-"
            text.removeFirst()
        }
        if text.first == "¥" { text.removeFirst() }
        var parts = text.split(separator: ".", omittingEmptySubsequences: false)
        parts[0].removeAll { ",_ ".contains($0) }
        guard parts.count <= 2, parts.contains(where: { !$0.isEmpty }),
              parts.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }) else {
            throw .notANumber
        }
        // Sixteen digits stay below `limit`.
        let digits = parts[0].drop { $0 == "0" }
        guard digits.count <= 16 else { throw .tooLarge }
        self.init(isNegative: negative, integer: UInt64(digits) ?? 0, fraction: parts.count == 2 ? String(parts[1]) : "")
        // Rounding 9999…9.995 to the fen would carry past what 万/亿 can say.
        guard fen / 100 < Self.limit else { throw .tooLarge }
    }

    /// The amount in fen, rounded half up at the third decimal.
    var fen: UInt64 {
        let digits = Array(fraction.compactMap(\.wholeNumberValue)) + [0, 0, 0]
        let fen = integer * 100 + UInt64(digits[0] * 10 + digits[1])
        return digits[2] >= 5 ? fen + 1 : fen
    }

    /// Full-width digits and signs from a Chinese keyboard, and the minus
    /// signs other apps copy, as their ASCII forms.
    private static func halfWidth(_ character: Character) -> Character {
        switch character {
        case "０"..."９": return Character(String(character.wholeNumberValue!))
        case "．", "。": return "."
        case "，": return ","
        case "－", "−", "—": return "-"
        case "＋": return "+"
        case "￥": return "¥"
        case "　", "\t", "\n": return " "
        default: return character
        }
    }
}

extension Character {
    /// 0–9 alone; a range check on `Character` would also take 1️⃣.
    var isASCIIDigit: Bool { asciiValue.map { (48...57).contains($0) } ?? false }
}

extension ArabicNumber {
    /// Plain digits, as a calculator or spreadsheet takes them: "-1234.5".
    var digits: String {
        (isNegative && !isZero ? "-" : "") + String(integer) + (fraction.isEmpty ? "" : "." + fraction)
    }
}
