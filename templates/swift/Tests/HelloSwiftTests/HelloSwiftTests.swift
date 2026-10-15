import PrismExtensionTesting
import Testing
@testable import HelloSwift

@Suite("Hello Swift")
struct HelloSwiftTests {
    @Test("greeting counts in Prism's state and reads the excited preference")
    func greet() async throws {
        let prism = try await PrismTestHost(HelloSwift(), preferences: ["excited": .bool(true)])
        #expect(try await prism.run("greet") == .keepOpen(message: "Hello from Swift! That makes 1."))
        #expect(await prism.state["greetings"] == .number(1))
        #expect(try await prism.status("greet")?.text == "Greeted once")
    }

    @Test("reset forgets the count")
    func reset() async throws {
        let prism = try await PrismTestHost(HelloSwift(), state: ["greetings": .number(3)])
        #expect(try await prism.run("reset") == .done)
        #expect(await prism.state["greetings"] == nil)
    }
}
