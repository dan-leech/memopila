import Foundation
@testable import MemopilaCore

/// Keyboard layouts for layout-convert tests. The app builds the real ones from `UCKeyTranslate`.
enum LayoutConvertFixtures {
    // MARK: Fixture layouts (US · Russian · a Ukrainian-like variant)

    static let usID = "fixture.us"
    static let ruID = "fixture.ru"
    static let uaID = "fixture.ua"

    /// US QWERTY ↔ Russian PC (ЙЦУКЕН), letters + punctuation on letter keys.
    static let usToRu: [Character: Character] = {
        let pairs: [(Character, Character)] = [
            ("q", "й"), ("w", "ц"), ("e", "у"), ("r", "к"), ("t", "е"), ("y", "н"), ("u", "г"),
            ("i", "ш"), ("o", "щ"), ("p", "з"), ("[", "х"), ("]", "ъ"),
            ("a", "ф"), ("s", "ы"), ("d", "в"), ("f", "а"), ("g", "п"), ("h", "р"), ("j", "о"),
            ("k", "л"), ("l", "д"), (";", "ж"), ("'", "э"),
            ("z", "я"), ("x", "ч"), ("c", "с"), ("v", "м"), ("b", "и"), ("n", "т"), ("m", "ь"),
            (",", "б"), (".", "ю"), ("`", "ё"),
            ("Q", "Й"), ("W", "Ц"), ("E", "У"), ("R", "К"), ("T", "Е"), ("Y", "Н"), ("U", "Г"),
            ("I", "Ш"), ("O", "Щ"), ("P", "З"), ("{", "Х"), ("}", "Ъ"),
            ("A", "Ф"), ("S", "Ы"), ("D", "В"), ("F", "А"), ("G", "П"), ("H", "Р"), ("J", "О"),
            ("K", "Л"), ("L", "Д"), (":", "Ж"), ("\"", "Э"),
            ("Z", "Я"), ("X", "Ч"), ("C", "С"), ("V", "М"), ("B", "И"), ("N", "Т"), ("M", "Ь"),
            ("<", "Б"), (">", "Ю"), ("~", "Ё"),
        ]
        return Dictionary(uniqueKeysWithValues: pairs)
    }()

    static let ruToUs: [Character: Character] = Dictionary(uniqueKeysWithValues: usToRu.map { ($0.value, $0.key) })

    /// Russian with a few Ukrainian letters (`s`→`і`, `]`→`ї`, `'`→`є`) — a third layout whose
    /// output differs from Russian, so orbit steps are distinguishable.
    static let usToUa: [Character: Character] = {
        var map = usToRu
        map["s"] = "і"
        map["S"] = "І"
        map["]"] = "ї"
        map["}"] = "Ї"
        map["'"] = "є"
        map["\""] = "Є"
        return map
    }()

    static let uaToUs: [Character: Character] = Dictionary(uniqueKeysWithValues: usToUa.map { ($0.value, $0.key) })

    /// Latin vs Cyrillic letter sets, as best-fit sees them for a mistype.
    static var scriptCharsets: [String: Set<Character>] {
        let latin = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ[]{};':\",.<>/`~")
        return [usID: latin, ruID: Set(usToRu.values), uaID: Set(usToUa.values)]
    }

    static var maps: [String: [String: [Character: Character]]] {
        [
            usID: [ruID: usToRu, uaID: usToUa],
            ruID: [usID: ruToUs],
            uaID: [usID: uaToUs],
        ]
    }

    // MARK: Real macOS IDs (ABC · Spanish-ISO · Russian) — two Latin layouts with equal letters

    static let abc = "com.apple.keylayout.ABC"
    static let spanish = "com.apple.keylayout.Spanish-ISO"
    static let russian = "com.apple.keylayout.Russian"
    static let latin = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let cyrillic = Set("абвгдеёжзийклмнопрстуфхцчшщъыьэюяАБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ")
    static var realCharsets: [String: Set<Character>] { [abc: latin, spanish: latin, russian: cyrillic] }
}
