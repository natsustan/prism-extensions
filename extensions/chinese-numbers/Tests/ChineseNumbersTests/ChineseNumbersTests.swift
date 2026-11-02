import PrismExtensionKit
import PrismExtensionTesting
import Testing
@testable import ChineseNumbers

@Suite("Convert to Chinese Numbers")
struct ChineseNumbersTests {
    private func list(_ query: String) async throws -> ExtensionList {
        let prism = try await PrismTestHost(ChineseNumbers())
        return try await prism.list(ChineseNumbers.CommandID.convert, query: query)
    }

    @Test("an empty query asks for a number, and the extension filters itself")
    func empty() async throws {
        let list = try await list("  ")
        #expect(list.items.isEmpty)
        #expect(list.filtering == .extension)
        #expect(list.emptyMessage?.title == "Type a Number")
    }

    @Test("digits show lowercase, uppercase, and amount rows that paste on Return")
    func digits() async throws {
        let list = try await list("100111.11")
        #expect(list.items.map(\.id) == ["lowercase", "uppercase", "amount"])
        #expect(list.items.map(\.title) == ["十万零一百一十一点一一", "壹拾万零壹佰壹拾壹点壹壹", "壹拾万零壹佰壹拾壹元壹角壹分"])
        #expect(list.items.map(\.subtitle) == ["小写", "大写", "金额大写"])
        let actions = list.items[2].actions
        #expect(actions.map(\.id) == ["paste", "copy"])
        #expect(actions[0].kind == .paste(text: "壹拾万零壹佰壹拾壹元壹角壹分"))
        #expect(actions[1].kind == .copy(text: "壹拾万零壹佰壹拾壹元壹角壹分"))
        #expect(actions[1].shortcut == ExtensionShortcut("cmd+shift+c"))
    }

    @Test("row IDs stay the same as the query changes")
    func stableIDs() async throws {
        #expect(try await list("1").items.map(\.id) == list("23456").items.map(\.id))
    }

    @Test("Chinese numbers show one row of digits")
    func chinese() async throws {
        let list = try await list("人民币壹佰元伍角")
        #expect(list.items.map(\.id) == ["arabic"])
        #expect(list.items.first?.title == "100.5")
        #expect(list.items.first?.actions.first?.kind == .paste(text: "100.5"))
    }

    @Test("a number too large, or text that isn't a number, says so")
    func refusals() async throws {
        let large = try await list("12345678901234567")
        #expect(large.items.isEmpty && large.emptyMessage?.title == "Number Too Large")
        let text = try await list("hello")
        #expect(text.items.isEmpty && text.emptyMessage?.title == "Not a Number")
    }

    @Test("an unknown list is a failure")
    func unknownCommand() async throws {
        let prism = try await PrismTestHost(ChineseNumbers())
        await #expect(throws: (any Error).self) { try await prism.list("other") }
    }
}
