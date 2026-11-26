import Foundation

/// Search words for Chinese text, so typing pinyin finds a host: “书房电脑”
/// becomes `shufangdiannao` (full pinyin) and `sfdn` (initials).
enum PinyinKeywords {
    static func keywords(for text: String) -> [String] {
        guard containsHan(text) else { return [] }
        let latin = NSMutableString(string: text)
        CFStringTransform(latin, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(latin, nil, kCFStringTransformStripDiacritics, false)
        let syllables = (latin as String).lowercased()
            .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        guard !syllables.isEmpty else { return [] }
        return [syllables.joined(), String(syllables.compactMap(\.first))]
    }

    static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isHan)
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: true
        default: false
        }
    }
}
