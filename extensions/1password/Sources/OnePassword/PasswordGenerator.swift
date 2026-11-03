import Foundation
import Security

/// The passwords Generate Password offers, made on the Mac from the system's
/// secure random source; nothing is sent to 1Password or saved.
enum PasswordRecipe: String, CaseIterable, Sendable {
    case random20 = "random-20"
    case random32 = "random-32"
    case lettersAndDigits = "letters-digits-20"
    case pin = "pin-6"

    static let lowercase = Array("abcdefghijkmnopqrstuvwxyz")
    static let uppercase = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
    static let digits = Array("23456789")
    static let symbols = Array("!#$%&*+-.:;=?@^_~")

    var length: Int {
        switch self {
        case .random20, .lettersAndDigits: 20
        case .random32: 32
        case .pin: 6
        }
    }

    var summary: String {
        switch self {
        case .random20, .random32: localized("\(length) characters with letters, digits, and symbols")
        case .lettersAndDigits: localized("\(length) characters with letters and digits")
        case .pin: localized("\(length)-digit PIN")
        }
    }

    /// Each set the password draws one character from at least.
    /// Look-alikes (l, I, O, 0, 1) are left out of letters and digits, so a
    /// password read aloud or typed from another screen comes out right; a
    /// PIN keeps every digit.
    var sets: [[Character]] {
        switch self {
        case .random20, .random32: [Self.lowercase, Self.uppercase, Self.digits, Self.symbols]
        case .lettersAndDigits: [Self.lowercase, Self.uppercase, Self.digits]
        case .pin: [Array("0123456789")]
        }
    }
}

struct PasswordGenerator: Sendable {
    /// A uniform integer in `0..<bound`.
    let random: @Sendable (Int) -> Int

    static let secure = PasswordGenerator { bound in
        // Rejection sampling keeps every value equally likely.
        let limit = UInt32.max - UInt32.max % UInt32(bound)
        while true {
            var value: UInt32 = 0
            let status = withUnsafeMutableBytes(of: &value) { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
            precondition(status == errSecSuccess, "The system's random source failed.")
            if value < limit { return Int(value % UInt32(bound)) }
        }
    }

    /// A password of the recipe's length with a character from each of its
    /// sets, at places chosen at random.
    func password(_ recipe: PasswordRecipe) -> String {
        let sets = recipe.sets
        let all = sets.flatMap { $0 }
        var characters = (0..<recipe.length).map { _ in all[random(all.count)] }
        // One from each set, then shuffled in, so no set is left out and
        // none keeps a fixed place.
        for (place, set) in sets.enumerated() where place < characters.count {
            characters[place] = set[random(set.count)]
        }
        for index in stride(from: characters.count - 1, to: 0, by: -1) {
            characters.swapAt(index, random(index + 1))
        }
        return String(characters)
    }
}

/// The passwords the open Generate Password list shows, so the one pasted
/// is the one on screen. Only in memory, and replaced on every load.
actor GeneratedPasswords {
    private var passwords: [String: String] = [:]

    func replace(with passwords: [String: String]) {
        self.passwords = passwords
    }

    func password(for id: String) -> String? {
        passwords[id]
    }
}
