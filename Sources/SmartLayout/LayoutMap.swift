import Foundation

/// Соответствие клавиш QWERTY (US) и ЙЦУКЕН (Русская).
enum LayoutMap {
    private static let enLower = Array("`qwertyuiop[]asdfghjkl;'zxcvbnm,./")
    private static let ruLower = Array("ёйцукенгшщзхъфывапролджэячсмитьбю.")
    private static let enUpper = Array("~QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>?")
    private static let ruUpper = Array("ЁЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ,")

    static let enToRu: [Character: Character] = {
        var m = [Character: Character]()
        for (e, r) in zip(enLower, ruLower) { m[e] = r }
        for (e, r) in zip(enUpper, ruUpper) { m[e] = r }
        return m
    }()

    static let ruToEn: [Character: Character] = {
        var m = [Character: Character]()
        for (e, r) in zip(enLower, ruLower) where r != "." { m[r] = e }
        for (e, r) in zip(enUpper, ruUpper) where r != "," { m[r] = e }
        return m
    }()

    /// Символы английской раскладки, которые в русской являются буквами.
    static let enKeysThatAreRuLetters: Set<Character> = Set("`[];',.~{}:\"<>")

    /// Перевод строки, набранной в раскладке `from` ("en" или "ru"), в другую раскладку.
    static func convert(_ text: String, from: String) -> String {
        let map = from == "en" ? enToRu : ruToEn
        return String(text.map { map[$0] ?? $0 })
    }

    /// Разделитель, набранный в EN, но предназначенный для RU (Shift+цифры и "/").
    static func delimiterEnToRu(_ c: Character) -> Character {
        let m: [Character: Character] = ["/": ".", "?": ",", "&": "?", "^": ":", "$": ";", "@": "\"", "#": "№"]
        return m[c] ?? c
    }
}
