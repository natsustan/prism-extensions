/// Writes placeholder text from a seed, so the text in the list, its detail
/// pane, and what Return pastes are the same words, even across separate requests.
struct LoremGenerator {
    static let paragraphLengths = 4...8

    /// The classic opening, used in Latin when “Start with Lorem ipsum” is on.
    static let opening = ["lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit"]

    /// The pseudo-Latin vocabulary Lorem Ipsum is usually drawn from.
    static let latinWords = [
        "a", "ac", "accumsan", "ad", "adipiscing", "aenean", "aliquam", "aliquet",
        "amet", "ante", "aptent", "arcu", "at", "auctor", "augue", "bibendum", "blandit", "class",
        "commodo", "condimentum", "congue", "consectetur", "consequat", "conubia", "convallis", "cras",
        "cubilia", "curabitur", "curae", "cursus", "dapibus", "diam", "dictum", "dictumst", "dignissim",
        "dis", "dolor", "dolore", "donec", "dui", "duis", "efficitur", "egestas", "eget", "eiusmod",
        "eleifend", "elementum", "elit", "enim", "erat", "eros", "est", "et", "etiam", "eu", "euismod",
        "ex", "facilisi", "facilisis", "fames", "faucibus", "felis", "fermentum", "feugiat", "finibus",
        "fringilla", "fusce", "gravida", "habitant", "habitasse", "hac", "hendrerit", "himenaeos",
        "iaculis", "id", "imperdiet", "in", "inceptos", "integer", "interdum", "ipsum", "justo", "labore",
        "lacinia", "lacus", "laoreet", "lectus", "leo", "libero", "ligula", "litora", "lobortis", "lorem",
        "luctus", "maecenas", "magna", "magnis", "malesuada", "massa", "mattis", "mauris", "maximus",
        "metus", "mi", "molestie", "mollis", "montes", "morbi", "mus", "nam", "nascetur", "natoque",
        "nec", "neque", "netus", "nibh", "nisi", "nisl", "non", "nostra", "nulla", "nullam", "nunc",
        "odio", "orci", "ornare", "parturient", "pellentesque", "penatibus", "per", "pharetra",
        "phasellus", "placerat", "platea", "porta", "porttitor", "posuere", "potenti", "praesent",
        "pretium", "primis", "proin", "pulvinar", "purus", "quam", "quis", "quisque", "rhoncus",
        "ridiculus", "risus", "rutrum", "sagittis", "sapien", "scelerisque", "sed", "sem", "semper",
        "senectus", "sit", "sociosqu", "sodales", "sollicitudin", "suscipit", "suspendisse", "taciti",
        "tellus", "tempor", "tempus", "tincidunt", "torquent", "tortor", "tristique", "turpis",
        "ullamcorper", "ultrices", "ultricies", "urna", "ut", "varius", "vehicula", "vel", "velit",
        "venenatis", "vestibulum", "vitae", "vivamus", "viverra", "volutpat", "vulputate",
    ]

    private let language: LoremLanguage
    private var random: SplitMix64
    private var opensWithLorem: Bool

    init(language: LoremLanguage, seed: UInt64, startsWithLorem: Bool) {
        self.language = language
        random = SplitMix64(seed: seed)
        opensWithLorem = startsWithLorem && language == .latin
    }

    static func text(_ request: LoremRequest, seed: UInt64, startsWithLorem: Bool) -> String {
        // Mixing in the row gives each row its own text from one seed.
        let row = UInt64(request.count) &* 31 &+ request.kind.seedSalt &+ request.language.seedSalt
        var generator = LoremGenerator(
            language: request.language, seed: SplitMix64.mix(seed ^ SplitMix64.mix(row)),
            startsWithLorem: startsWithLorem
        )
        switch request.kind {
        case .paragraphs: return generator.paragraphs(request.count)
        case .sentences: return generator.sentences(request.count)
        case .words: return generator.words(request.count)
        }
    }

    mutating func paragraphs(_ count: Int) -> String {
        (0..<count).map { _ in sentences(Int.random(in: Self.paragraphLengths, using: &random)) }
            .joined(separator: "\n\n")
    }

    mutating func sentences(_ count: Int) -> String {
        (0..<count).map { _ in sentence() }.joined(separator: language.wordSeparator)
    }

    /// Words separated by spaces, with no punctuation; in Chinese and
    /// Japanese, exactly that many characters.
    mutating func words(_ count: Int) -> String {
        if language.countsCharacters {
            var text = ""
            while text.count < count {
                text += language == .chinese ? ChineseLorem.clause(using: &random) : randomWord()
            }
            return String(text.prefix(count))
        }
        var words = [String]()
        if opensWithLorem {
            words = Array(Self.opening.prefix(count))
            opensWithLorem = false
        }
        while words.count < count {
            words.append(randomWord())
        }
        return words.joined(separator: " ")
    }

    private mutating func sentence() -> String {
        if opensWithLorem {
            opensWithLorem = false
            return "Lorem ipsum dolor sit amet, consectetur adipiscing elit."
        }
        if language == .chinese {
            return ChineseLorem.sentence(using: &random)
        }
        var words = (0..<Int.random(in: language.sentenceLengths, using: &random)).map { _ in randomWord() }
        if let ending = language.endings.randomElement(using: &random) {
            words[words.count - 1] = ending
        }
        // Longer sentences sometimes pause, as prose does.
        if words.count >= 8, Bool.random(using: &random) {
            let index = Int.random(in: 2...(words.count - 4), using: &random)
            words[index] += language.comma
        }
        if language.capitalizes {
            words[0] = words[0].prefix(1).uppercased() + words[0].dropFirst()
        }
        return words.joined(separator: language.wordSeparator) + language.period
    }

    private mutating func randomWord() -> String {
        let words = language.words
        return words[Int.random(in: 0..<words.count, using: &random)]
    }
}

/// A small, fast generator whose output depends only on its seed, unlike
/// `SystemRandomNumberGenerator`.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        return Self.mix(state)
    }

    static func mix(_ value: UInt64) -> UInt64 {
        var z = value
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
