/// Reads Chinese numbers back into Arabic digits: lowercase or uppercase
/// numerals with units (一万零五, 壹拾贰), digit by digit (二〇二六),
/// decimals (三点一四), and amounts in words (壹佰元伍角).
enum ChineseNumberParser {
    static let digits: [Character: Int] = [
        "零": 0, "〇": 0, "○": 0,
        "一": 1, "壹": 1, "幺": 1, "二": 2, "贰": 2, "貳": 2, "两": 2, "兩": 2,
        "三": 3, "叁": 3, "參": 3, "四": 4, "肆": 4, "五": 5, "伍": 5,
        "六": 6, "陆": 6, "陸": 6, "七": 7, "柒": 7, "八": 8, "捌": 8, "九": 9, "玖": 9,
    ]
    static let units: [Character: UInt64] = [
        "十": 10, "拾": 10, "百": 100, "佰": 100, "千": 1000, "仟": 1000,
    ]
    static let scales: [Character: UInt64] = [
        "万": 10_000, "萬": 10_000, "亿": 100_000_000, "億": 100_000_000,
    ]

    /// The number, or nil when the text isn't one this reads.
    static func parse(_ input: String) -> ArabicNumber? {
        var text = input.filter { !$0.isWhitespace }
        if text.hasPrefix("人民币") { text.removeFirst(3) }
        var negative = false
        if let first = text.first, "负負-".contains(first) {
            negative = true
            text.removeFirst()
        }
        if text.hasPrefix("人民币") { text.removeFirst(3) }
        guard !text.isEmpty else { return nil }
        let number = text.contains(where: { "元圆圓角分".contains($0) }) ? amount(text) : plain(text)
        guard var number else { return nil }
        number.isNegative = negative && !number.isZero
        return number
    }

    /// 三点一四: an integer, then digit by digit after 点.
    private static func plain(_ text: String) -> ArabicNumber? {
        let point = text.firstIndex { $0 == "点" || $0 == "點" }
        let whole = String(text[..<(point ?? text.endIndex)])
        var fraction = ""
        if let point {
            let tail = text[text.index(after: point)...]
            let values = tail.compactMap { digits[$0] }
            guard !tail.isEmpty, values.count == tail.count else { return nil }
            fraction = values.map(String.init).joined()
        }
        guard let integer = whole.isEmpty ? 0 : integer(whole) else { return nil }
        return ArabicNumber(integer: integer, fraction: fraction)
    }

    /// 壹佰元伍角陆分, 伍角, 壹仟元整.
    private static func amount(_ text: String) -> ArabicNumber? {
        var rest = Substring(text)
        if rest.last == "整" || rest.last == "正" { rest.removeLast() }
        var yuan: UInt64 = 0
        if let index = rest.firstIndex(where: { "元圆圓".contains($0) }) {
            guard index > rest.startIndex, let value = integer(String(rest[..<index])) else { return nil }
            yuan = value
            rest = rest[rest.index(after: index)...]
        }
        // Zeros are skipped, so 0 means "not seen yet".
        var jiao = 0, fen = 0
        var pending: Int?
        var afterZero = false
        for character in rest {
            if let digit = digits[character] {
                if digit == 0 && pending == nil {
                    afterZero = true
                    continue
                }
                guard pending == nil else { return nil }
                pending = digit
            } else if character == "角", pending == nil, afterZero, jiao == 0, fen == 0 {
                // 壹佰元零角伍分, as some cheques write it.
                afterZero = false
            } else if character == "角", let digit = pending, jiao == 0, fen == 0 {
                jiao = digit
                pending = nil
            } else if character == "分", let digit = pending, fen == 0 {
                fen = digit
                pending = nil
            } else {
                return nil
            }
        }
        guard pending == nil else { return nil }
        var fraction = "\(jiao)\(fen)"
        while fraction.last == "0" { fraction.removeLast() }
        return ArabicNumber(integer: yuan, fraction: fraction)
    }

    /// 一万零五 or 二〇二六. Units fall in order within each 万 group, and a
    /// bare last digit reads as people say it (一万五 is 15000, 三百五 is 350).
    /// Nil past `ArabicNumber.limit`.
    static func integer(_ text: String) -> UInt64? {
        let characters = Array(text)
        guard !characters.isEmpty else { return nil }
        if characters.allSatisfy({ digits[$0] != nil }) {
            guard characters.count <= 16 else { return nil }
            return characters.reduce(UInt64(0)) { $0 * 10 + UInt64(digits[$1]!) }
        }
        var yi: UInt64 = 0, wan: UInt64 = 0, group: UInt64 = 0
        var digit: UInt64?
        var afterZero = false
        /// The last unit or scale: units must fall below it, and a bare
        /// digit after it is a tenth of it (一万五).
        var place: UInt64?
        for character in characters {
            if let value = digits[character] {
                guard digit == nil else { return nil }
                if value == 0 {
                    afterZero = true
                } else {
                    digit = UInt64(value)
                }
            } else if let unit = units[character] {
                // 十五 and 十万: a leading 十 means 一十.
                let count = digit ?? (unit == 10 && group == 0 && !afterZero ? 1 : 0)
                guard unit < place ?? .max, count > 0 else { return nil }
                group += count * unit
                place = unit
                digit = nil
                afterZero = false
            } else if let scale = scales[character] {
                let value = group + (digit ?? 0)
                if scale == 10_000 {
                    guard wan == 0, value > 0 else { return nil }
                    wan = value * scale
                } else {
                    guard yi == 0, wan + value > 0 else { return nil }
                    yi = (wan + value) * scale
                    wan = 0
                }
                group = 0
                digit = nil
                afterZero = false
                place = scale
            } else {
                return nil
            }
        }
        var tail = digit ?? 0
        if !afterZero, let place, place >= 100 { tail = tail * place / 10 }
        let value = yi + wan + group + tail
        return value < ArabicNumber.limit ? value : nil
    }
}
