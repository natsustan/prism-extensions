/// The language the text looks like. The raw value is the ⌘P filter ID and
/// starts the row's item ID. Every vocabulary is a word list written for this
/// extension, so the text means nothing and quotes no one.
enum LoremLanguage: String, CaseIterable, Sendable {
    case latin = "la"
    case chinese = "zh"
    case japanese = "ja"
    case korean = "ko"
    case german = "de"
    case french = "fr"

    /// Each language's own name, as macOS lists languages.
    var title: String {
        switch self {
        case .latin: "Latin"
        case .chinese: "中文"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .german: "Deutsch"
        case .french: "Français"
        }
    }

    /// Chinese and Japanese don't put spaces between words, so a “word”
    /// there is a character.
    var countsCharacters: Bool { self == .chinese || self == .japanese }

    var wordSeparator: String { countsCharacters ? "" : " " }
    var comma: String {
        switch self {
        case .chinese: "，"
        case .japanese: "、"
        default: ","
        }
    }
    var period: String { countsCharacters ? "。" : "." }
    var capitalizes: Bool { self == .latin || self == .german || self == .french }

    var sentenceLengths: ClosedRange<Int> {
        switch self {
        case .japanese: 4...12
        default: 4...16
        }
    }

    var seedSalt: UInt64 { UInt64(Self.allCases.firstIndex(of: self) ?? 0) << 32 }

    /// What sentences are drawn from. Chinese builds clauses instead
    /// (`ChineseLorem`), so its nouns stand in here.
    var words: [String] {
        switch self {
        case .latin: LoremGenerator.latinWords
        case .chinese: ChineseLorem.nouns
        case .japanese: Self.japanesePhrases
        case .korean: Self.koreanWords
        case .german: Self.germanWords
        case .french: Self.frenchWords
        }
    }

    /// Japanese and Korean sentences end in a verb, so their last word comes
    /// from here; empty means any word can end a sentence.
    var endings: [String] {
        switch self {
        case .japanese: Self.japaneseEndings
        case .korean: Self.koreanEndings
        default: []
        }
    }

    private static let japanesePhrases = [
        "風が", "空の", "遠くへ", "静かな", "町を", "歩いて", "光が", "水の", "音が", "森の", "道を",
        "ゆっくりと", "小さな", "青い", "白い", "雲が", "川に", "夜の", "朝の", "花を", "窓から", "季節が",
        "言葉を", "時間が", "どこか", "いつも", "まだ", "もう", "少しずつ", "やわらかな", "広い", "古い",
        "新しい", "海へ", "山の", "星が", "月を", "雨に", "街の", "人々が", "子どもたちは", "心に",
        "ひとりで", "一緒に", "向こうに", "手紙を", "記憶の", "景色を", "ふたたび", "そっと",
    ]

    private static let japaneseEndings = [
        "見えました", "ありました", "続いています", "流れていた", "広がっていく", "聞こえる", "残っている",
        "消えていった", "光っていました", "待っています", "変わりました", "静かです", "やってくる",
        "戻ってきた",
    ]

    private static let koreanWords = [
        "바람이", "하늘을", "조용한", "오래된", "길을", "따라", "천천히", "작은", "푸른", "하얀", "구름이",
        "강물이", "숲속의", "밤하늘에", "아침", "햇살이", "꽃이", "창밖으로", "계절이", "시간이", "어딘가",
        "언제나", "아직", "이미", "조금씩", "부드러운", "넓은", "새로운", "바다로", "산의", "별이", "달을",
        "비가", "거리의", "사람들이", "아이들이", "마음에", "혼자서", "함께", "저편에", "편지를", "풍경을",
        "다시", "살며시", "우리는", "그리고", "하지만", "그날", "오늘도", "기억을",
    ]

    private static let koreanEndings = [
        "있습니다", "보였다", "흘러간다", "들려온다", "빛났다", "기다린다", "변했습니다", "아름답다",
        "다가온다", "돌아왔다", "사라졌다", "이어진다", "펼쳐진다", "머물렀다",
    ]

    private static let germanWords = [
        "und", "der", "die", "das", "ein", "eine", "mit", "auf", "über", "unter", "nach", "vor", "durch",
        "im", "am", "zum", "nicht", "noch", "schon", "immer", "wieder", "nur", "auch", "sehr", "fast",
        "leise", "langsam", "hell", "weit", "still", "warm", "klar", "neu", "alt", "klein", "groß",
        "schön", "ruhig", "Wind", "Licht", "Stadt", "Himmel", "Wasser", "Wald", "Weg", "Garten",
        "Fenster", "Morgen", "Abend", "Nacht", "Sommer", "Winter", "Regen", "Sonne", "Wolken", "Fluss",
        "Berge", "Straße", "Haus", "Zeit", "Welt", "Worte", "Buchstaben", "Zeilen", "Seite", "Text",
        "Bild", "Farbe", "Stimme", "Ferne", "Ufer", "Meer", "Insel", "Brücke", "Blindtext", "Absatz",
        "Satz", "Gedanke", "Raum", "Tag", "Jahr", "geht", "kommt", "bleibt", "liegt", "steht", "fließt",
        "scheint", "fällt", "wartet", "beginnt", "endet", "findet", "sieht", "hört", "trägt", "zieht",
        "wächst", "leuchtet", "schweigt", "erzählt",
    ]

    private static let frenchWords = [
        "le", "la", "les", "un", "une", "des", "et", "dans", "sur", "sous", "avec", "pour", "sans",
        "vers", "entre", "depuis", "encore", "toujours", "déjà", "jamais", "doucement", "lentement",
        "très", "peu", "bien", "loin", "près", "ici", "clair", "calme", "léger", "ancien", "nouveau",
        "petit", "grand", "beau", "douce", "lumière", "vent", "ville", "ciel", "eau", "forêt", "chemin",
        "jardin", "fenêtre", "matin", "soir", "nuit", "été", "hiver", "pluie", "soleil", "nuages",
        "rivière", "montagne", "rue", "maison", "temps", "monde", "mots", "lettres", "lignes", "page",
        "texte", "image", "couleur", "voix", "rivage", "mer", "île", "pont", "souvenir", "pensée", "jour",
        "année", "fleurs", "oiseaux", "enfants", "silence", "paysage", "va", "vient", "reste", "passe",
        "coule", "brille", "tombe", "attend", "commence", "finit", "trouve", "voit", "entend", "porte",
        "grandit", "raconte", "rêve", "chante", "marche",
    ]
}
