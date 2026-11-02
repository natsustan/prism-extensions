import Testing
@testable import ChineseNumbers

@Suite("Chinese to Arabic")
struct ChineseNumberParserTests {
    @Test("numbers with units, in either set of numerals", arguments: [
        ("零", "0"), ("十", "10"), ("十五", "15"), ("二十", "20"), ("一百零一", "101"), ("一千零五", "1005"),
        ("十万零一百一十一", "100111"), ("壹拾万零壹佰壹拾壹", "100111"), ("两万", "20000"),
        ("一亿零五百万", "105000000"), ("一万亿", "1000000000000"), ("一万二千三百四十五亿", "1234500000000"),
        ("一亿二千万", "120000000"), ("負貳佰", "-200"), ("负零", "0"),
    ])
    func units(input: String, digits: String) {
        #expect(ChineseNumberParser.parse(input)?.digits == digits)
    }

    @Test("digit by digit, colloquial endings, and decimals", arguments: [
        ("二〇二六", "2026"), ("一二三", "123"), ("一万五", "15000"), ("三百五", "350"), ("两千三", "2300"),
        ("二十五", "25"), ("一万零五", "10005"), ("三点一四", "3.14"), ("点五", "0.5"), ("十二点零五", "12.05"),
    ])
    func shorthand(input: String, digits: String) {
        #expect(ChineseNumberParser.parse(input)?.digits == digits)
    }

    @Test("amounts in words", arguments: [
        ("壹佰元整", "100"), ("人民币壹拾万零壹佰壹拾壹元壹角壹分", "100111.11"), ("伍角", "0.5"),
        ("壹佰元零伍分", "100.05"), ("叁元贰角", "3.2"), ("零元整", "0"), ("一百块", nil),
        ("伍角整", "0.5"), ("负人民币壹佰元", "-100"), ("壹佰元零角伍分", "100.05"), ("壹佰元零角", "100"),
    ] as [(String, String?)])
    func amounts(input: String, digits: String?) {
        #expect(ChineseNumberParser.parse(input)?.digits == digits)
    }

    @Test("text that isn't a Chinese number is refused", arguments: [
        "", "负", "百", "十十", "百十千", "一二百", "一万万", "一亿亿", "三点", "五角四角", "元", "hello",
        "一万八千九百九十九亿九千九百九十九万九千九百九十九九",
    ])
    func refusals(input: String) {
        #expect(ChineseNumberParser.parse(input) == nil)
    }

    @Test("every number reads back from its own lowercase, uppercase, and amount")
    func roundTrip() throws {
        for text in ["0", "7", "15", "101", "1005", "100111", "105000000", "1234500000000", "9999999999999999", "3.14"] {
            let number = try ArabicNumber(parsing: text)
            #expect(ChineseNumberParser.parse(ChineseNumberFormatter.lowercase(number)) == number)
            #expect(ChineseNumberParser.parse(ChineseNumberFormatter.uppercase(number)) == number)
        }
        for text in ["0.5", "100.05", "1234.56", "100111.11"] {
            let number = try ArabicNumber(parsing: text)
            #expect(ChineseNumberParser.parse(ChineseNumberFormatter.amount(number))?.digits == number.digits)
        }
    }
}
