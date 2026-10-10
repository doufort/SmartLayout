import AppKit

struct Fix {
    enum Kind { case layout, spelling }
    let original: String      // что было набрано
    let replacement: String   // на что заменить
    let switchTo: String?     // на какую раскладку переключить ("en"/"ru"), если нужно
    let kind: Kind
}

/// Решает, набрано ли слово не в той раскладке и нет ли в нём ошибки.
final class CorrectionEngine {
    private let checker = NSSpellChecker.shared
    private let tag = NSSpellChecker.uniqueSpellDocumentTag()
    private let store: WordStore
    private var langCache = [String: String]()

    // Кэши, чтобы не спрашивать проверщик macOS повторно.
    private var validCache = [String: Bool]()
    private var prefixCache = [String: Bool]()
    private let cacheLimit = 20_000

    init(store: WordStore) { self.store = store }

    func clearCaches() {
        validCache.removeAll()
        prefixCache.removeAll()
    }

    /// Код языка проверщика macOS ("en" -> "en" или "en_US", "ru" -> "ru").
    private func spellLanguage(_ lang: String) -> String {
        if let c = langCache[lang] { return c }
        let available = checker.availableLanguages
        let found = available.first { $0 == lang } ?? available.first { $0.hasPrefix(lang) } ?? lang
        langCache[lang] = found
        return found
    }

    static func isRuLetter(_ c: Character) -> Bool {
        ("а"..."я").contains(c) || ("А"..."Я").contains(c) || c == "ё" || c == "Ё"
    }

    static func isEnLetter(_ c: Character) -> Bool { c.isASCII && c.isLetter }

    /// Делит токен на префикс, «ядро» (от первой до последней буквы) и суффикс.
    private func split(_ token: String, lang: String) -> (String, String, String) {
        let isLetter: (Character) -> Bool = lang == "ru" ? Self.isRuLetter : Self.isEnLetter
        guard let first = token.firstIndex(where: isLetter),
              let last = token.lastIndex(where: isLetter) else { return (token, "", "") }
        return (String(token[..<first]), String(token[first...last]), String(token[token.index(after: last)...]))
    }

    func isValid(_ word: String, lang: String) -> Bool {
        if store.contains(word) { return true }
        let isLetter: (Character) -> Bool = lang == "ru" ? Self.isRuLetter : Self.isEnLetter
        guard word.allSatisfy({ isLetter($0) || $0 == "-" || $0 == "'" || $0 == "’" }) else { return false }
        let key = lang + ":" + word.lowercased()
        if let cached = validCache[key] { return cached }
        let range = checker.checkSpelling(of: word, startingAt: 0, language: spellLanguage(lang),
                                          wrap: false, inSpellDocumentWithTag: tag, wordCount: nil)
        let ok = range.location == NSNotFound
        if validCache.count > cacheLimit { validCache.removeAll() }
        validCache[key] = ok
        return ok
    }

    /// Есть ли в словаре языка слова, начинающиеся с `prefix`.
    func hasCompletions(_ prefix: String, lang: String) -> Bool {
        let isLetter: (Character) -> Bool = lang == "ru" ? Self.isRuLetter : Self.isEnLetter
        guard prefix.allSatisfy(isLetter) else { return false }
        let key = lang + ":" + prefix.lowercased()
        if let cached = prefixCache[key] { return cached }
        let range = NSRange(location: 0, length: (prefix as NSString).length)
        let list = checker.completions(forPartialWordRange: range, in: prefix,
                                       language: spellLanguage(lang), inSpellDocumentWithTag: tag) ?? []
        let ok = !list.isEmpty || store.words.contains { $0.hasPrefix(prefix.lowercased()) }
        if prefixCache.count > cacheLimit { prefixCache.removeAll() }
        prefixCache[key] = ok
        return ok
    }

    // MARK: Опечатки

    private func spellingFix(core: String, lang: String) -> String? {
        // 1. Словарь частых ошибок: быстро и точно.
        if let known = store.typoFix(core) { return TextUtils.matchCase(known, like: core) }
        guard Settings.shared.autocorrectGuess, core.count >= 3, core != core.uppercased() else { return nil }
        // 2. Проверщик macOS, но принимаем только близкие варианты.
        let range = NSRange(location: 0, length: (core as NSString).length)
        guard let suggestion = checker.correction(forWordRange: range, in: core,
                                                  language: spellLanguage(lang),
                                                  inSpellDocumentWithTag: tag),
              suggestion.lowercased() != core.lowercased() else { return nil }
        let maxDistance = core.count <= 4 ? 1 : 2
        guard TextUtils.editDistance(core, suggestion) <= maxDistance else { return nil }
        // Первая буква редко бывает ошибкой: не меняем её у коротких слов.
        if core.count <= 5, core.first?.lowercased() != suggestion.first?.lowercased() { return nil }
        return TextUtils.matchCase(suggestion, like: core)
    }

    // MARK: Решение

    private func looksRussian(enCore: String, ruCore: String) -> Bool {
        guard ruCore.count >= 3 else { return false }
        if enCore.dropFirst().dropLast().contains(where: { LayoutMap.enKeysThatAreRuLetters.contains($0) }) {
            return true
        }
        let enVowels = Set("aeiouyAEIOUY")
        let ruVowels = Set("аеёиоуыэюяАЕЁИОУЫЭЮЯ")
        if enCore.count >= 4, !enCore.contains(where: { enVowels.contains($0) }),
           ruCore.contains(where: { ruVowels.contains($0) }) {
            return true
        }
        return false
    }

    /// Проверка законченного слова (на пробеле, Enter, знаке препинания).
    func evaluate(token: String, layout: String) -> Fix? {
        let settings = Settings.shared
        guard token.count >= 2, !token.contains(where: \.isNumber) else { return nil }
        guard layout == "en" || layout == "ru" else { return nil }
        if store.isException(token) { return nil }

        let from = layout, to = layout == "en" ? "ru" : "en"
        let (pre, core, suf) = split(token, lang: from)

        // Частая опечатка из словаря исправляется даже если слово «существует» (dont, im).
        if settings.autocorrect, let known = store.typoFix(core) {
            return Fix(original: token, replacement: pre + TextUtils.matchCase(known, like: core) + suf,
                       switchTo: nil, kind: .spelling)
        }

        if !core.isEmpty && isValid(core, lang: from) { return nil }

        if settings.autoSwitch {
            let converted = LayoutMap.convert(token, from: from)
            let (cPre, cCore, cSuf) = split(converted, lang: to)
            if cCore.count >= 2 {
                if isValid(cCore, lang: to) || (from == "en" && looksRussian(enCore: core, ruCore: cCore)) {
                    return Fix(original: token, replacement: converted, switchTo: to, kind: .layout)
                }
                // Не та раскладка + опечатка: ghbdtn с ошибкой -> исправленное русское слово.
                if settings.autocorrect, !hasCompletions(String(core.prefix(3)), lang: from),
                   let fixed = spellingFix(core: cCore, lang: to) {
                    return Fix(original: token, replacement: cPre + fixed + cSuf, switchTo: to, kind: .layout)
                }
            }
        }

        if settings.autocorrect, let fixed = spellingFix(core: core, lang: from) {
            return Fix(original: token, replacement: pre + fixed + suf, switchTo: nil, kind: .spelling)
        }
        // Незнакомое слово оставлено как есть: возможно, это ваш сленг. После 3 раз запомним.
        if core.count >= 2 { store.learning.noteUnknown(core); validCache.removeValue(forKey: from + ":" + core.lowercased()) }
        return nil
    }

    /// Раннее определение раскладки по первым буквам слова (3–5 букв).
    /// Срабатывает, только если в текущем языке нет слов с таким началом,
    /// а в другом языке есть.
    func evaluatePrefix(_ prefix: String, layout: String) -> Fix? {
        guard Settings.shared.autoSwitch, (3...5).contains(prefix.count) else { return nil }
        guard layout == "en" || layout == "ru", !store.isException(prefix) else { return nil }
        let to = layout == "en" ? "ru" : "en"
        let converted = LayoutMap.convert(prefix, from: layout)
        let isFromLetter: (Character) -> Bool = layout == "ru" ? Self.isRuLetter : Self.isEnLetter
        let isToLetter: (Character) -> Bool = to == "ru" ? Self.isRuLetter : Self.isEnLetter
        // Буквы (или ;'[], для русского) должны полностью превращаться в буквы другого языка.
        guard converted.allSatisfy(isToLetter) else { return nil }
        // Если в текущей раскладке есть такое начало слова — ждём конца слова.
        if prefix.allSatisfy(isFromLetter) && hasCompletions(prefix, lang: layout) { return nil }
        guard hasCompletions(converted, lang: to) else { return nil }
        return Fix(original: prefix, replacement: converted, switchTo: to, kind: .layout)
    }
}
