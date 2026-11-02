import Testing
@testable import ChineseNumbers

@Suite("Arabic to Chinese")
struct ChineseNumberFormatterTests {
    private func number(_ text: String) throws -> ArabicNumber {
        try ArabicNumber(parsing: text)
    }

    @Test("lowercase follows the spoken zero and 十 rules", arguments: [
        ("0", "零"), ("7", "七"), ("10", "十"), ("15", "十五"), ("20", "二十"), ("101", "一百零一"),
        ("110", "一百一十"), ("1005", "一千零五"), ("1050", "一千零五十"), ("10000", "一万"),
        ("10005", "一万零五"), ("100111", "十万零一百一十一"), ("150000", "十五万"),
        ("12345678", "一千二百三十四万五千六百七十八"), ("100000000", "一亿"),
        ("100000001", "一亿零一"), ("105000000", "一亿零五百万"), ("100100000", "一亿零一十万"),
        ("1000000000000", "一万亿"), ("1234500000000", "一万二千三百四十五亿"),
        ("9999999999999999", "九千九百九十九万九千九百九十九亿九千九百九十九万九千九百九十九"),
    ])
    func lowercase(input: String, expected: String) throws {
        #expect(ChineseNumberFormatter.lowercase(try number(input)) == expected)
    }

    @Test("uppercase keeps 壹拾 and reads decimals digit by digit", arguments: [
        ("10", "壹拾"), ("100111", "壹拾万零壹佰壹拾壹"), ("3.14", "叁点壹肆"), ("0.50", "零点伍零"),
        ("-12", "负壹拾贰"), ("-0", "零"),
    ])
    func uppercase(input: String, expected: String) throws {
        #expect(ChineseNumberFormatter.uppercase(try number(input)) == expected)
    }

    @Test("lowercase reads decimals and signs", arguments: [
        ("3.14", "三点一四"), (".5", "零点五"), ("-15.5", "负十五点五"),
    ])
    func lowercaseDecimals(input: String, expected: String) throws {
        #expect(ChineseNumberFormatter.lowercase(try number(input)) == expected)
    }

    @Test("amounts round to the fen and end in 整 unless they reach 分", arguments: [
        ("0", "零元整"), ("1", "壹元整"), ("100111.11", "壹拾万零壹佰壹拾壹元壹角壹分"),
        ("0.5", "伍角整"), ("0.05", "伍分"), ("100.05", "壹佰元零伍分"), ("100.5", "壹佰元伍角整"),
        ("1234.56", "壹仟贰佰叁拾肆元伍角陆分"), ("0.995", "壹元整"), ("1.004", "壹元整"),
        ("-3.2", "负叁元贰角整"), ("-0.001", "零元整"),
    ])
    func amounts(input: String, expected: String) throws {
        #expect(ChineseNumberFormatter.amount(try number(input)) == expected)
    }

    @Test("input may carry separators, currency signs, and full-width digits", arguments: [
        ("1,234,567", "1234567"), ("¥ 12.5", "12.5"), ("￥１２３．４", "123.4"), ("１２，３４５", "12345"),
        ("−8", "-8"), ("+8", "8"), ("007", "7"), ("12.", "12"), ("-¥1,234.00", "-1234.00"),
        ("¥-5", "-5"), (" 1 234 ", "1234"),
    ])
    func messyInput(input: String, digits: String) throws {
        #expect(try number(input).digits == digits)
    }

    @Test("text that isn't a number, or is too large, is refused")
    func refusals() {
        for text in ["", "-", ".", "1.2.3", "12a", "1e5", "一百", "$100", "1.234,56", "1.2 3", "1️⃣"] {
            #expect(throws: ArabicNumber.ParseError.notANumber) { try ArabicNumber(parsing: text) }
        }
        #expect(throws: ArabicNumber.ParseError.tooLarge) { try ArabicNumber(parsing: "10000000000000000") }
        // Rounding to the fen would carry into 亿亿.
        #expect(throws: ArabicNumber.ParseError.tooLarge) { try ArabicNumber(parsing: "9999999999999999.995") }
        #expect((try? ArabicNumber(parsing: "9999999999999999.994")) != nil)
        #expect((try? ArabicNumber(parsing: "0009999999999999999")) != nil)
    }
}
