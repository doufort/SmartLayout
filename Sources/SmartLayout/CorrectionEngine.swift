import AppKit

struct Fix {
    enum Kind { case layout, spelling }
    let original: String      // что было набрано
    let replacement: String   // на что заменить
    let switchTo: String?     // на какую раскладку переключить ("en"/"ru"), если нужно
    let kind: Kind
}

/// Слово и язык, для которых нужен ответ проверщика macOS.
struct WordKey: Hashable {
    let word: String
    let lang: String
}

/// Счётчик ответов для `prefetch` (меняется только на главном потоке).
private final class Countdown {
    private var left: Int
    init(_ n: Int) { left = n }
    /// true, когда пришёл последний ответ.
    func tick() -> Bool { left -= 1; return left == 0 }
}

/// Что делать с законченным словом.
enum Decision {
    case fix(Fix)
    case keep
    /// Ответ зависит от проверщика macOS: сначала `prefetch`, потом снова `evaluateCached`.
    /// Пустой набор — нужен медленный путь (догадка словаря macOS), а не проверка слов.
    case pending(Set<WordKey>)
}

/// Решает, набрано ли слово не в той раскладке и нет ли в нём ошибки.
///
/// Во время набора движок не ждёт проверщик macOS: сначала смотрит частотный словарь
/// (`Lexicon`) и кэш, а если ответа нет, обработчик нажатий пропускает клавишу дальше,
/// а слово проверяется в фоне (`prefetch`) и исправляется следом.
final class CorrectionEngine {
    private let checker = NSSpellChecker.shared
    private let tag = NSSpellChecker.uniqueSpellDocumentTag()
    private let store: WordStore
    private(set) var lexicon: Lexicon
    private var langCache = [String: String]()

    // Кэши, чтобы не спрашивать проверщик macOS повторно.
    private var validCache = [String: Bool]()
    private var prefixCache = [String: Bool]()
    private let cacheLimit = 20_000
    /// Проверщик macOS иногда отвечает секунду и дольше (первая загрузка словаря, нагрузка).
    /// Синхронно его спрашивают только Enter/Tab; если ответ был медленным,
    /// на минуту и они обходятся кэшем.
    static let slowCallLimit: TimeInterval = 0.3
    private(set) var slowUntil: Date?

    /// По умолчанию словарь пустой: приложение загружает его в фоне (`Lexicon.loadInBackground`)
    /// и передаёт сюда через `use(_:)`.
    init(store: WordStore, lexicon: Lexicon = Lexicon([:])) {
        self.store = store
        self.lexicon = lexicon
    }

    /// Подключить загруженный словарь (на главном потоке).
    func use(_ lexicon: Lexicon) {
        self.lexicon = lexicon
        prefixCache.removeAll()   // ответы без словаря могли быть другими
    }

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

    private static func cacheKey(_ word: String, _ lang: String) -> String { lang + ":" + word.lowercased() }

    /// Есть ли такое слово. `cachedOnly`: не спрашивать проверщик, вернуть nil, если ответа нет.
    func validity(_ word: String, lang: String, cachedOnly: Bool) -> Bool? {
        if store.contains(word) { return true }
        let isLetter: (Character) -> Bool = lang == "ru" ? Self.isRuLetter : Self.isEnLetter
        guard word.allSatisfy({ isLetter($0) || $0 == "-" || $0 == "'" || $0 == "’" }) else { return false }
        if lexicon.contains(word, lang: lang) { return true }
        let key = Self.cacheKey(word, lang)
        if let cached = validCache[key] { return cached }
        if cachedOnly { return nil }
        let started = Date()
        let range = checker.checkSpelling(of: word, startingAt: 0, language: spellLanguage(lang),
                                          wrap: false, inSpellDocumentWithTag: tag, wordCount: nil)
        noteDuration(since: started)
        let ok = range.location == NSNotFound
        remember(key, ok)
        return ok
    }

    func isValid(_ word: String, lang: String) -> Bool { validity(word, lang: lang, cachedOnly: false) ?? false }

    private func remember(_ key: String, _ ok: Bool) {
        if validCache.count > cacheLimit { validCache.removeAll() }
        validCache[key] = ok
    }

    /// Проверить слова в фоне (`requestChecking` не блокирует поток) и запомнить ответы.
    /// `completion` вызывается на главном потоке, когда готовы все ответы.
    func prefetch(_ keys: Set<WordKey>, completion: @escaping () -> Void) {
        guard !keys.isEmpty else { DispatchQueue.main.async { completion() }; return }
        let left = Countdown(keys.count)
        for k in keys {
            let range = NSRange(location: 0, length: (k.word as NSString).length)
            let options: [NSSpellChecker.OptionKey: Any] = [
                .orthography: NSOrthography.defaultOrthography(forLanguage: k.lang)
            ]
            checker.requestChecking(of: k.word, range: range, types: NSTextCheckingResult.CheckingType.spelling.rawValue,
                                    options: options, inSpellDocumentWithTag: tag) { [weak self] _, results, _, _ in
                let ok = !results.contains { $0.resultType == .spelling }
                DispatchQueue.main.async {
                    self?.remember(Self.cacheKey(k.word, k.lang), ok)
                    if left.tick() { completion() }
                }
            }
        }
    }

    /// Есть ли слова, начинающиеся с `prefix`: частотный словарь и ваши слова,
    /// без обращения к проверщику (если частотного словаря нет — по старинке, через проверщик).
    func hasCompletions(_ prefix: String, lang: String) -> Bool {
        let isLetter: (Character) -> Bool = lang == "ru" ? Self.isRuLetter : Self.isEnLetter
        guard prefix.allSatisfy(isLetter) else { return false }
        let lower = prefix.lowercased()
        if !lexicon.isEmpty && lexicon.hasPrefix(lower, lang: lang) { return true }
        let key = Self.cacheKey(lower, lang)
        if let cached = prefixCache[key] { return cached }
        var ok = store.words.contains { $0.hasPrefix(lower) }
        if !ok && lexicon.isEmpty {
            let range = NSRange(location: 0, length: (prefix as NSString).length)
            let started = Date()
            ok = !(checker.completions(forPartialWordRange: range, in: prefix,
                                       language: spellLanguage(lang), inSpellDocumentWithTag: tag) ?? []).isEmpty
            noteDuration(since: started)
        }
        if prefixCache.count > cacheLimit { prefixCache.removeAll() }
        prefixCache[key] = ok
        return ok
    }

    func noteDuration(since start: Date, now: Date = Date()) {
        if now.timeIntervalSince(start) > Self.slowCallLimit { slowUntil = now.addingTimeInterval(60) }
    }

    var isSlow: Bool { slowUntil.map { Date() < $0 } ?? false }

    /// Первый запрос к словарям медленный: делаем его при запуске, а не на первом слове.
    /// Запрос фоновый, поэтому набор в это время не тормозит.
    func warmUp() {
        prefetch([WordKey(word: "превед", lang: "ru"), WordKey(word: "helo", lang: "en")]) {}
    }

    // MARK: Опечатки

    private enum Spelling { case fixed(String), none, needsChecker }

    private func spellingFix(core: String, lang: String, cachedOnly: Bool) -> Spelling {
        // 1. Словарь частых ошибок: быстро и точно.
        if let known = store.typoFix(core) { return .fixed(TextUtils.matchCase(known, like: core)) }
        guard Settings.shared.autocorrectGuess, core.count >= 3, core != core.uppercased() else { return .none }
        if cachedOnly { return .needsChecker }
        // 2. Проверщик macOS, но принимаем только близкие варианты.
        let range = NSRange(location: 0, length: (core as NSString).length)
        guard let suggestion = checker.correction(forWordRange: range, in: core,
                                                  language: spellLanguage(lang),
                                                  inSpellDocumentWithTag: tag),
              suggestion.lowercased() != core.lowercased() else { return .none }
        let maxDistance = core.count <= 4 ? 1 : 2
        guard TextUtils.editDistance(core, suggestion) <= maxDistance else { return .none }
        // Первая буква редко бывает ошибкой: не меняем её у коротких слов.
        if core.count <= 5, core.first?.lowercased() != suggestion.first?.lowercased() { return .none }
        return .fixed(TextUtils.matchCase(suggestion, like: core))
    }

    // MARK: Решение

    private func looksRussian(enCore: String, ruCore: String) -> Bool {
        guard ruCore.count >= 3 else { return false }
        // Адреса и сокращения (google.com, mail.ru, e.g.) тоже содержат «.,;'» внутри,
        // но в русском нет слов с таким началом: «пщщпд…», «ьфшдю…», «уюпю».
        // Берём 5 букв, а не 3: у github.io начало «пше» (пшено), а «пшерг» уже ни на что не похоже.
        guard hasCompletions(String(ruCore.prefix(5)), lang: "ru") else { return false }
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

    /// Проверка законченного слова (на пробеле, Enter, знаке препинания); может спросить проверщик.
    func evaluate(token: String, layout: String) -> Fix? {
        if case .fix(let fix) = decide(token: token, layout: layout, cachedOnly: false) { return fix }
        return nil
    }

    /// То же без обращения к проверщику: годится для обработчика нажатий.
    func evaluateCached(token: String, layout: String) -> Decision {
        decide(token: token, layout: layout, cachedOnly: true)
    }

    private func decide(token: String, layout: String, cachedOnly: Bool) -> Decision {
        let settings = Settings.shared
        guard token.count >= 2, !token.contains(where: \.isNumber) else { return .keep }
        guard layout == "en" || layout == "ru" else { return .keep }
        if store.isException(token) { return .keep }

        let from = layout, to = layout == "en" ? "ru" : "en"
        let (pre, core, suf) = split(token, lang: from)

        // Частая опечатка из словаря исправляется даже если слово «существует» (dont, im).
        if settings.autocorrect, let known = store.typoFix(core) {
            return .fix(Fix(original: token, replacement: pre + TextUtils.matchCase(known, like: core) + suf,
                            switchTo: nil, kind: .spelling))
        }

        // Сначала собираем все нужные ответы; если чего-то нет в кэше — решение откладывается.
        var missing = Set<WordKey>()
        if !core.isEmpty {
            switch validity(core, lang: from, cachedOnly: cachedOnly) {
            case true?: return .keep
            case nil: missing.insert(WordKey(word: core, lang: from))
            case false?: break
            }
        }
        let converted = LayoutMap.convert(token, from: from)
        let (cPre, cCore, cSuf) = split(converted, lang: to)
        var convertedValid = false
        if settings.autoSwitch, cCore.count >= 2 {
            switch validity(cCore, lang: to, cachedOnly: cachedOnly) {
            case nil: missing.insert(WordKey(word: cCore, lang: to))
            case let v?: convertedValid = v
            }
        }
        if !missing.isEmpty { return .pending(missing) }

        if settings.autoSwitch, cCore.count >= 2 {
            if convertedValid || (from == "en" && looksRussian(enCore: core, ruCore: cCore)) {
                return .fix(Fix(original: token, replacement: converted, switchTo: to, kind: .layout))
            }
            // Не та раскладка + опечатка: ghbdtn с ошибкой -> исправленное русское слово.
            if settings.autocorrect, !hasCompletions(String(core.prefix(3)), lang: from) {
                switch spellingFix(core: cCore, lang: to, cachedOnly: cachedOnly) {
                case .fixed(let fixed):
                    return .fix(Fix(original: token, replacement: cPre + fixed + cSuf, switchTo: to, kind: .layout))
                case .needsChecker: return .pending([])
                case .none: break
                }
            }
        }

        if settings.autocorrect {
            switch spellingFix(core: core, lang: from, cachedOnly: cachedOnly) {
            case .fixed(let fixed):
                return .fix(Fix(original: token, replacement: pre + fixed + suf, switchTo: nil, kind: .spelling))
            case .needsChecker: return .pending([])
            case .none: break
            }
        }
        // Незнакомое слово оставлено как есть: возможно, это ваш сленг. После 3 раз запомним.
        if core.count >= 2 {
            store.learning.noteUnknown(core)
            validCache.removeValue(forKey: Self.cacheKey(core, from))
        }
        return .keep
    }

    /// Раннее определение раскладки по первым буквам слова.
    /// Срабатывает, только если в текущем языке нет слов с таким началом, а в другом языке есть.
    /// С частотным словарём — с 4-й буквы: на трёх буквах редкие настоящие слова
    /// чаще принимаются за другую раскладку.
    func evaluatePrefix(_ prefix: String, layout: String) -> Fix? {
        let minLength = lexicon.isEmpty ? 3 : 4
        guard Settings.shared.autoSwitch, (minLength...5).contains(prefix.count), !isSlow else { return nil }
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
