import Foundation

/// An account the CLI can use (`op account list`).
struct OnePasswordAccount: Decodable, Hashable, Sendable {
    var url: String
    var email: String
    var accountUUID: String

    enum CodingKeys: String, CodingKey {
        case url, email
        case accountUUID = "account_uuid"
    }

    /// How sections, filters, and messages name the account: its email,
    /// or its sign-in address when `op` gave none.
    var name: String { email.isEmpty ? url : email }
}

/// An item as `op item list` describes it: no secrets, only what the row
/// shows and what finds it.
struct OnePasswordItem: Decodable, Hashable, Sendable {
    struct Vault: Decodable, Hashable, Sendable {
        var id: String
        var name: String
    }

    struct Link: Decodable, Hashable, Sendable {
        var href: String
        var primary: Bool?
    }

    var id: String
    var title: String
    var category: String
    var vault: Vault
    /// The username of a login, the masked number of a card, and so on.
    var additionalInformation: String?
    var urls: [Link]?
    var favorite: Bool?
    var tags: [String]?
    /// When the item last changed, as `op` writes it (`2025-06-01T08:30:00Z`).
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, title, category, vault, urls, favorite, tags
        case additionalInformation = "additional_information"
        case updatedAt = "updated_at"
    }

    /// `updatedAt` as a date; nil when missing or unreadable.
    var updated: Date? {
        guard let updatedAt else { return nil }
        return (try? Date(updatedAt, strategy: .iso8601))
            ?? (try? Date(updatedAt, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }

    /// The website a login opens: the primary link, or the first.
    var website: URL? {
        let links = urls ?? []
        let href = (links.first { $0.primary == true } ?? links.first)?.href
        guard let href, let url = URL(string: href), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return url
    }
}

/// The kinds of item 1Password has, as the CLI names them.
enum OnePasswordCategory {
    /// Categories with a `password` field to paste, as in Raycast's extension.
    static let withPassword: Set<String> = ["LOGIN", "PASSWORD"]

    /// Categories offered in ⌘P, in 1Password's order.
    static let filtered = ["LOGIN", "PASSWORD", "SECURE_NOTE", "CREDIT_CARD", "IDENTITY", "API_CREDENTIAL", "SSH_KEY", "DOCUMENT"]

    static func title(_ category: String) -> String {
        switch category {
        case "LOGIN": localized("Login")
        case "PASSWORD": localized("Password")
        case "SECURE_NOTE": localized("Secure Note")
        case "CREDIT_CARD": localized("Credit Card")
        case "IDENTITY": localized("Identity")
        case "API_CREDENTIAL": localized("API Credential")
        case "SSH_KEY": localized("SSH Key")
        case "DOCUMENT": localized("Document")
        case "DATABASE": localized("Database")
        case "SERVER": localized("Server")
        case "SOFTWARE_LICENSE": localized("Software License")
        case "BANK_ACCOUNT": localized("Bank Account")
        case "WIRELESS_ROUTER": localized("Wireless Router")
        case "EMAIL_ACCOUNT": localized("Email Account")
        case "MEMBERSHIP": localized("Membership")
        case "REWARD_PROGRAM": localized("Reward Program")
        case "PASSPORT": localized("Passport")
        case "DRIVER_LICENSE": localized("Driver License")
        case "OUTDOOR_LICENSE": localized("Outdoor License")
        case "SOCIAL_SECURITY_NUMBER": localized("Social Security Number")
        case "MEDICAL_RECORD": localized("Medical Record")
        case "CRYPTO_WALLET": localized("Crypto Wallet")
        // A category newer than this list, as 1Password names it.
        default: category.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
        }
    }

    /// The plural shown in ⌘P, for the categories in `filtered`.
    static func pluralTitle(_ category: String) -> String {
        switch category {
        case "LOGIN": localized("Logins")
        case "PASSWORD": localized("Passwords")
        case "SECURE_NOTE": localized("Secure Notes")
        case "CREDIT_CARD": localized("Credit Cards")
        case "IDENTITY": localized("Identities")
        case "API_CREDENTIAL": localized("API Credentials")
        case "SSH_KEY": localized("SSH Keys")
        case "DOCUMENT": localized("Documents")
        default: title(category) + "s"
        }
    }

    /// The empty state of a category filter, as a whole phrase.
    static func noneTitle(_ category: String) -> String {
        switch category {
        case "LOGIN": localized("No Logins")
        case "PASSWORD": localized("No Passwords")
        case "SECURE_NOTE": localized("No Secure Notes")
        case "CREDIT_CARD": localized("No Credit Cards")
        case "IDENTITY": localized("No Identities")
        case "API_CREDENTIAL": localized("No API Credentials")
        case "SSH_KEY": localized("No SSH Keys")
        case "DOCUMENT": localized("No Documents")
        default: localized("No \(pluralTitle(category))")
        }
    }

    static func symbol(_ category: String) -> String {
        switch category {
        case "LOGIN": "key"
        case "PASSWORD": "key.horizontal"
        case "SECURE_NOTE": "note.text"
        case "CREDIT_CARD": "creditcard"
        case "IDENTITY": "person.text.rectangle"
        case "DOCUMENT": "doc"
        case "API_CREDENTIAL": "chevron.left.forwardslash.chevron.right"
        case "SSH_KEY": "terminal"
        case "DATABASE": "cylinder.split.1x2"
        case "SERVER": "server.rack"
        case "SOFTWARE_LICENSE": "app.badge.checkmark"
        case "BANK_ACCOUNT": "building.columns"
        case "WIRELESS_ROUTER": "wifi.router"
        case "EMAIL_ACCOUNT": "envelope"
        case "MEMBERSHIP", "REWARD_PROGRAM": "wallet.pass"
        case "PASSPORT", "DRIVER_LICENSE", "OUTDOOR_LICENSE": "person.crop.rectangle"
        case "SOCIAL_SECURITY_NUMBER": "number"
        case "MEDICAL_RECORD": "cross.case"
        case "CRYPTO_WALLET": "bitcoinsign.circle"
        default: "doc.text"
        }
    }

    static func tint(_ category: String) -> String {
        switch category {
        case "LOGIN", "PASSWORD": "blue"
        case "SECURE_NOTE": "gold"
        case "CREDIT_CARD", "BANK_ACCOUNT": "green"
        case "IDENTITY", "PASSPORT", "DRIVER_LICENSE", "OUTDOOR_LICENSE", "MEMBERSHIP", "REWARD_PROGRAM": "teal"
        case "API_CREDENTIAL", "SSH_KEY", "DATABASE", "SERVER": "indigo"
        case "MEDICAL_RECORD": "red"
        default: "gray"
        }
    }
}

extension Sequence<OnePasswordItem> {
    /// The list's order: the item changed most recently first, as the one
    /// just saved or edited is usually the one wanted; items without a date
    /// go last, and ties go by title. Each date is parsed once, since a
    /// vault can hold thousands of items.
    func newestFirst() -> [OnePasswordItem] {
        map { ($0, $0.updated) }
            .sorted { a, b in
                switch (a.1, b.1) {
                case let (left?, right?) where left != right: left > right
                case (.some, nil): true
                case (nil, .some): false
                default: a.0.title.localizedStandardCompare(b.0.title) == .orderedAscending
                }
            }
            .map(\.0)
    }
}
