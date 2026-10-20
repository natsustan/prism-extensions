import Foundation

/// The user's names for ports, from the Port Names preference:
/// `3000 Web, 5432 Postgres`. `3000=Web` and `3000: Web` read the same.
struct PortNames: Equatable, Sendable {
    let names: [Int: String]

    init(_ text: String) {
        var names: [Int: String] = [:]
        for entry in text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline }) {
            let entry = entry.trimmingCharacters(in: .whitespaces)
            let digits = entry.prefix(while: \.isASCIIDigit)
            guard let port = Int(digits), (0...65535).contains(port) else { continue }
            let name = entry.dropFirst(digits.count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "=:"))
                .trimmingCharacters(in: .whitespaces)
            // The first name given for a port wins.
            if !name.isEmpty, names[port] == nil { names[port] = name }
        }
        self.names = names
    }

    subscript(port: Int) -> String? { names[port] }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
