import Carbon
import Foundation

/// Какие символы дают одни и те же клавиши в английской и русской раскладках.
struct KeyTable {
    /// Символ EN → символ RU на той же клавише (буквенные клавиши).
    let enToRu: [Character: Character]
    /// Обратно, только для русских букв: точка и запятая — знаки в обеих раскладках.
    let ruToEn: [Character: Character]
    /// Символы EN, которые в RU являются буквами (`[];',.` и т.п.).
    let enKeysThatAreRuLetters: Set<Character>
    /// Знаки EN → знаки RU на той же клавише (Shift+цифры, "/"): разделитель после исправленного слова.
    let delimiters: [Character: Character]

    /// `letterKeys` — пары символов с буквенных клавиш, `otherKeys` — с цифрового ряда и прочих.
    init(letterKeys: [(Character, Character)], otherKeys: [(Character, Character)] = []) {
        var enToRu = [Character: Character](), ruToEn = [Character: Character]()
        var enKeys = Set<Character>(), delimiters = [Character: Character]()
        // Первая пара побеждает: на ISO-клавиатуре один и тот же символ бывает на двух клавишах
        // (§ и `), основные клавиши идут в списке раньше.
        for (e, r) in letterKeys where e != r && enToRu[e] == nil {
            enToRu[e] = r
            if Self.isCyrillic(r) && ruToEn[r] == nil { ruToEn[r] = e }
            if Self.isCyrillic(r) && !e.isLetter { enKeys.insert(e) }
        }
        for (e, r) in letterKeys + otherKeys where e != r && !e.isLetter && !r.isLetter && delimiters[e] == nil {
            delimiters[e] = r
        }
        self.enToRu = enToRu
        self.ruToEn = ruToEn
        self.enKeysThatAreRuLetters = enKeys
        self.delimiters = delimiters
    }

    /// Только русские буквы: в «Русская — ПК» на одной из клавиш есть латинская «Ë».
    static func isCyrillic(_ c: Character) -> Bool {
        ("а"..."я").contains(c) || ("А"..."Я").contains(c) || c == "ё" || c == "Ё"
    }

    /// Есть ли в таблице все 33 русские буквы в обоих регистрах.
    var hasAllRussianLetters: Bool {
        let letters = "абвгдеёжзийклмнопрстуфхцчшщъыьэюя"
        return (letters + letters.uppercased()).allSatisfy { ruToEn[$0] != nil }
    }
}

/// Соответствие клавиш QWERTY (US) и ЙЦУКЕН (Русская).
///
/// Таблица строится по раскладкам, которые реально включены у пользователя
/// (`UCKeyTranslate`), поэтому работает и с «Русская — ПК», и с Apple «Русская»,
/// где точка, запятая и знаки на Shift+цифры стоят на других клавишах.
/// Встроенная таблица «Русская — ПК» ниже — запасной вариант.
enum LayoutMap {
    private static let enLower = Array("`qwertyuiop[]asdfghjkl;'zxcvbnm,./")
    private static let ruLower = Array("ёйцукенгшщзхъфывапролджэячсмитьбю.")
    private static let enUpper = Array("~QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>?")
    private static let ruUpper = Array("ЁЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ,")

    /// Встроенная таблица (раскладки U.S. и «Русская — ПК»).
    static let builtIn = KeyTable(
        letterKeys: Array(zip(enLower + enUpper, ruLower + ruUpper)),
        otherKeys: [("&", "?"), ("^", ":"), ("$", ";"), ("@", "\""), ("#", "№")])

    /// Таблица, которой пользуемся сейчас.
    private(set) static var current = builtIn

    static var enToRu: [Character: Character] { current.enToRu }
    static var ruToEn: [Character: Character] { current.ruToEn }
    static var enKeysThatAreRuLetters: Set<Character> { current.enKeysThatAreRuLetters }

    /// Перестроить таблицу по включённым раскладкам (при запуске и при смене раскладки).
    static func reload() {
        guard let en = InputSource.source(language: "en"), let ru = InputSource.source(language: "ru"),
              let table = KeyboardLayouts.table(en: en, ru: ru) else {
            current = builtIn
            return
        }
        current = table
    }

    /// Перевод строки, набранной в раскладке `from` ("en" или "ru"), в другую раскладку.
    static func convert(_ text: String, from: String) -> String {
        let map = from == "en" ? enToRu : ruToEn
        return String(text.map { map[$0] ?? $0 })
    }

    /// Разделитель, набранный в EN, но предназначенный для RU (Shift+цифры и "/").
    static func delimiterEnToRu(_ c: Character) -> Character {
        current.delimiters[c] ?? c
    }
}

/// Чтение раскладок macOS через `UCKeyTranslate`.
enum KeyboardLayouts {
    /// Буквенные клавиши: `, Q…P, [, ], A…L, ;, ', Z…M, ",", ".", "/", "\" и клавиша слева от Z на ISO.
    /// Клавиша слева от «1» — код 50 на ANSI и код 10 на ISO (там коды 10 и 50 переставлены),
    /// поэтому она идёт первой: при совпадении символов побеждает первая клавиша.
    static func letterKeyCodes(iso: Bool) -> [UInt16] {
        let leftOfOne: [UInt16] = iso ? [10, 50] : [50, 10]
        return leftOfOne + [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30,
                            0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39,
                            6, 7, 8, 9, 11, 45, 46, 43, 47, 44, 42]
    }

    static var isISOKeyboard: Bool { Int(KBGetLayoutType(Int16(LMGetKbdType()))) == Int(kKeyboardISO) }
    /// Цифровой ряд: 1…0, "-", "=".
    static let otherKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24]

    /// Таблица для пары раскладок или nil, если в русской раскладке нашлись не все буквы.
    static func table(en: TISInputSource, ru: TISInputSource) -> KeyTable? {
        guard let enData = layoutData(en), let ruData = layoutData(ru) else { return nil }
        func pairs(_ codes: [UInt16]) -> [(Character, Character)] {
            var out = [(Character, Character)]()
            for shift in [false, true] {
                for code in codes {
                    if let e = character(code, shift: shift, in: enData),
                       let r = character(code, shift: shift, in: ruData) { out.append((e, r)) }
                }
            }
            return out
        }
        let table = KeyTable(letterKeys: pairs(letterKeyCodes(iso: isISOKeyboard)), otherKeys: pairs(otherKeyCodes))
        return table.hasAllRussianLetters ? table : nil
    }

    /// Раскладка по идентификатору, даже если она не включена (для тестов).
    static func source(id: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]
        return list?.first
    }

    private static func layoutData(_ source: TISInputSource) -> Data? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
    }

    private static func character(_ keyCode: UInt16, shift: Bool, in data: Data) -> Character? {
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let modifiers: UInt32 = shift ? (UInt32(shiftKey >> 8) & 0xFF) : 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(ptr, keyCode, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                                  UInt32(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length == 1, let scalar = Unicode.Scalar(chars[0]) else { return nil }
        let ch = Character(scalar)
        // Управляющие символы и пробелы не нужны.
        guard !ch.isWhitespace, scalar.value >= 0x20, scalar.value != 0x7F else { return nil }
        return ch
    }
}
