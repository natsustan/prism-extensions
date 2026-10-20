import Foundation
import PrismExtensionKit

/// A color the user picked or saved.
struct SavedColor: Codable, Hashable, Sendable {
    var color: RGBColor
    var savedAt: Date
    var isFavorite: Bool

    /// The HEX without `#`, or the Display P3 form for a color beyond sRGB,
    /// which HEX would clamp onto another: picking the same color again moves
    /// it to the top instead of adding it twice, and favorites and selection
    /// follow it.
    var id: String { color.isInSRGB ? String(color.hex.dropFirst()) : ColorFormat.displayP3.string(for: color) }
}

/// The saved colors, kept in Prism's state as one JSON string so they
/// survive the process stopping. Newest first.
struct SavedColors: Sendable {
    static let stateKey = "colors"
    /// Recent colors kept besides favorites, which are never dropped. About
    /// 100 bytes each, far inside the 1 MB state limit.
    static let recentLimit = 200

    private(set) var colors: [SavedColor]

    init(colors: [SavedColor] = []) {
        self.colors = colors
    }

    static func load(from context: PrismContext) async -> SavedColors {
        guard let json = await context.state(stateKey)?.stringValue else { return SavedColors() }
        do {
            return SavedColors(colors: try decoder.decode([SavedColor].self, from: Data(json.utf8)))
        } catch {
            await context.log("Saved colors could not be read and start empty: \(error)")
            return SavedColors()
        }
    }

    func save(to context: PrismContext) async throws {
        let json = String(decoding: try Self.encoder.encode(colors), as: UTF8.self)
        await context.setState(.string(json), for: Self.stateKey)
    }

    var favorites: [SavedColor] { colors.filter(\.isFavorite) }

    /// Puts the color on top, keeping a favorite a favorite.
    mutating func add(_ color: RGBColor, at date: Date) {
        var saved = SavedColor(color: color, savedAt: date, isFavorite: false)
        if let index = colors.firstIndex(where: { $0.id == saved.id }) {
            saved.isFavorite = colors.remove(at: index).isFavorite
        }
        colors.insert(saved, at: 0)
        var recent = 0
        colors.removeAll { saved in
            guard !saved.isFavorite else { return false }
            recent += 1
            return recent > Self.recentLimit
        }
    }

    mutating func setFavorite(_ isFavorite: Bool, id: String) {
        guard let index = colors.firstIndex(where: { $0.id == id }) else { return }
        colors[index].isFavorite = isFavorite
    }

    mutating func remove(id: String) {
        colors.removeAll { $0.id == id }
    }

    /// Clears everything but favorites.
    mutating func removeRecent() {
        colors.removeAll { !$0.isFavorite }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
