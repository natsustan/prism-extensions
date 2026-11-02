/// Writes Arabic numbers in Chinese: lowercase (一万零五), uppercase
/// financial numerals (壹万零伍), and amounts in words (壹万零伍元整), with
/// the zero rules of 《会计基础工作规范》.
enum ChineseNumberFormatter {
    struct Numerals: Sendable {
        let digits: [Character]
        /// 十, 百, 千.
        let units: [Character]
    }

    static let lowercase = Numerals(digits: Array("零一二三四五六七八九"), units: Array("十百千"))
    static let uppercase = Numerals(digits: Array("零壹贰叁肆伍陆柒捌玖"), units: Array("拾佰仟"))

    /// 一百二十三点四五; 10–19 at the start read 十X, as people say them.
    static func lowercase(_ number: ArabicNumber) -> String {
        var text = words(number.integer, in: lowercase)
        if text.hasPrefix("一十") { text.removeFirst() }
        return signed(number, text + decimals(number.fraction, in: lowercase))
    }

    /// 壹佰贰拾叁点肆伍; financial numerals always keep 壹拾.
    static func uppercase(_ number: ArabicNumber) -> String {
        signed(number, words(number.integer, in: uppercase) + decimals(number.fraction, in: uppercase))
    }

    /// 壹佰贰拾叁元肆角伍分, rounded to the fen. Amounts that stop at 元 or
    /// 角 end in 整, as 《会计基础工作规范》 asks; those with 分 don't.
    static func amount(_ number: ArabicNumber) -> String {
        let fen = number.fen
        let yuan = fen / 100, jiao = Int(fen / 10 % 10), cents = Int(fen % 10)
        let digits = uppercase.digits
        var text = yuan > 0 ? words(yuan, in: uppercase) + "元" : ""
        if fen % 100 == 0 {
            text = (yuan > 0 ? text : "零元") + "整"
        } else {
            if jiao > 0 {
                text += "\(digits[jiao])角"
            } else if yuan > 0 {
                text += "零"
            }
            text += cents > 0 ? "\(digits[cents])分" : "整"
        }
        return fen > 0 && number.isNegative ? "负" + text : text
    }

    /// The integer in words, below `ArabicNumber.limit`. A gap of zeros
    /// reads as one 零, and trailing zeros as nothing.
    static func words(_ value: UInt64, in numerals: Numerals) -> String {
        guard value > 0 else { return String(numerals.digits[0]) }
        for (scale, unit) in [(UInt64(100_000_000), "亿"), (10_000, "万")] where value >= scale {
            let rest = value % scale
            var text = words(value / scale, in: numerals) + unit
            if rest > 0 {
                // 一亿零五百万: the rest starts below its top digit.
                if rest < scale / 10 { text.append(numerals.digits[0]) }
                text += words(rest, in: numerals)
            }
            return text
        }
        return group(Int(value), in: numerals)
    }

    /// 1–9999 in words.
    private static func group(_ value: Int, in numerals: Numerals) -> String {
        var text = ""
        var pendingZero = false
        for (position, power) in [1000, 100, 10, 1].enumerated() {
            let digit = value / power % 10
            if digit == 0 {
                pendingZero = !text.isEmpty
                continue
            }
            if pendingZero { text.append(numerals.digits[0]) }
            pendingZero = false
            text.append(numerals.digits[digit])
            if position < 3 { text.append(numerals.units[2 - position]) }
        }
        return text
    }

    private static func decimals(_ fraction: String, in numerals: Numerals) -> String {
        guard !fraction.isEmpty else { return "" }
        return "点" + String(fraction.compactMap { $0.wholeNumberValue.map { numerals.digits[$0] } })
    }

    private static func signed(_ number: ArabicNumber, _ text: String) -> String {
        number.isNegative && !number.isZero ? "负" + text : text
    }
}
