import Foundation

/// Строгое правило «текст не должен выглядеть сгенерированным».
/// Основано на эссе Википедии «Признаки сгенерированности текста»:
/// https://ru.wikipedia.org/wiki/Википедия:Признаки_сгенерированности_текста
///
/// Работает в два слоя: правила в инструкции для модели и локальная проверка ответа.
/// Если ответ нарушает правила, модель получает список нарушений и переписывает;
/// если и вторая попытка не прошла, вариант не показывается.
enum HumanStyle {
    static let rules = """
    СТРОГИЕ ПРАВИЛА ЕСТЕСТВЕННОГО ТЕКСТА. Текст не должен выглядеть сгенерированным нейросетью:
    1. Пиши как этот же автор: его словами, длиной фраз и тоном. Не делай текст официальнее, пафоснее или восторженнее исходного.
    2. Не добавляй фактов, оценок, выводов, пояснений, оговорок и советов, которых нет в исходнике. Никаких «важно отметить», «стоит подчеркнуть», «в заключение», «таким образом», «подводя итог».
    3. Никакого рекламного языка: «уникальный», «невероятный», «ключевую роль», «богатое наследие», «яркий пример», «является свидетельством», «в современном мире», «неотъемлемая часть», «открывает новые горизонты».
    4. Не преувеличивай значимость обычных вещей и не ищи в них символизм. Не приписывай действия неодушевлённому («событие подчёркивает», «факт демонстрирует»).
    5. Не используй ради эффекта конструкции «не только…, но и…», «это не просто…, это…».
    6. Не группируй по три («быстро, удобно и надёжно») и не используй пары крайностей «от … до …», если этого не было в исходнике.
    7. Не заменяй повторяющееся слово синонимами ради разнообразия: повтор у человека нормален.
    8. Без громоздких деепричастных оборотов и канцелярита. Деепричастие должно относиться к тому же лицу, что и сказуемое.
    9. Длинное тире (—) только там, где его требует правило пунктуации. В остальных случаях запятая, двоеточие или скобки.
    10. Никакой разметки: без Markdown, звёздочек, решёток, жирного, списков, заголовков и эмодзи, если их не было в исходнике.
    11. Не обращайся к читателю и не комментируй свою работу: никаких «Вот исправленный вариант».
    12. Заглавная буква только в начале предложения и в именах собственных.
    """

    /// Обороты, типичные для сгенерированного текста (проверяются, только если их не было в исходнике).
    static let bannedPhrases = [
        "важно отметить", "стоит отметить", "стоит подчеркнуть", "следует отметить", "необходимо отметить",
        "в заключение", "подводя итог", "таким образом,", "в целом можно сказать",
        "играет ключевую роль", "играет важную роль", "ключевую роль", "неотъемлемой частью", "неотъемлемая часть",
        "является свидетельством", "свидетельствует о", "богатое наследие", "богатую историю", "в современном мире",
        "открывает новые горизонты", "новые горизонты", "уникальн", "невероятн", "поистине",
        "не только", "это не просто", "яркий пример", "погрузиться в", "давайте разберёмся", "давайте рассмотрим",
        "вот исправленный", "вот улучшенный", "вот вариант", "надеюсь, это", "подчёркивает важность",
        "it's important to note", "it is important to note", "in conclusion", "delve", "not only",
        "testament to", "plays a crucial role", "plays a vital role", "vibrant", "seamless", "rich heritage",
        "here is the", "here's the"
    ]

    /// «от … до …»: компилируется один раз, а не при каждой проверке.
    private static let fromTo = try! NSRegularExpression(pattern: #"\bот\s+\S+\s+до\s+\S+"#)

    private static func hasFromTo(_ s: String) -> Bool {
        fromTo.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// Поиск подстроки без юникодной нормализации Swift String: для коротких фраз
    /// в тексте до нескольких тысяч символов это в разы быстрее.
    private static func has(_ s: NSString, _ phrase: String) -> Bool {
        s.range(of: phrase, options: .literal).location != NSNotFound
    }

    static func violations(in text: String, original: String, slang: Set<String> = []) -> [String] {
        let t = text.lowercased(), o = original.lowercased()
        let tn = t as NSString, on = o as NSString
        let textCount = text.count, originalCount = original.count
        var v = [String]()

        // Сленг автора должен остаться: вариант не должен звучать «литературнее» автора.
        let words: (String) -> [String] = {
            $0.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "-" }).map(String.init)
        }
        let textWords = Set(words(text))
        let lost = Set(words(original)).filter { slang.contains($0) && !textWords.contains($0) }
        if !lost.isEmpty { v.append("заменены слова автора: \(lost.sorted().joined(separator: ", ")) (их нужно оставить как есть)") }

        for p in bannedPhrases where has(tn, p) && !has(on, p) { v.append("оборот «\(p)»") }

        // «от … до …»
        if hasFromTo(t), !hasFromTo(o) { v.append("пара крайностей «от … до …»") }

        // Длинные тире
        let dashes = text.filter { $0 == "—" }.count - original.filter { $0 == "—" }.count
        let sentences = max(1, text.split(whereSeparator: { ".!?…".contains($0) }).count)
        if dashes > max(1, sentences / 3) { v.append("слишком много длинных тире (\(dashes))") }

        // Разметка
        let markdownMarks = ["**", "__", "##", "```"]
        if markdownMarks.contains(where: { text.contains($0) && !original.contains($0) }) { v.append("разметка Markdown") }
        let listLine = text.split(separator: "\n").contains { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            return s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("# ") || s.hasPrefix("• ")
        }
        if listLine && !original.contains("\n- ") && !original.hasPrefix("- ") { v.append("списки или заголовки") }

        // Эмодзи, которых не было
        let emoji: (String) -> Int = { $0.unicodeScalars.filter { $0.properties.isEmojiPresentation }.count }
        if emoji(text) > emoji(original) { v.append("эмодзи") }

        // Сильно длиннее исходника — значит, что-то додумано
        if textCount > Int(Double(originalCount) * 1.6) + 30 { v.append("текст стал заметно длиннее исходного") }

        // Слова С Заглавной Буквы подряд (как в заголовках)
        let tokens = text.split(whereSeparator: \.isWhitespace)
        var capsRun = 0, maxRun = 0
        for w in tokens {
            if let f = w.first, f.isUppercase, w.count > 3 { capsRun += 1; maxRun = max(maxRun, capsRun) } else { capsRun = 0 }
        }
        if maxRun >= 4 && maxRun > originalCapsRun(original) { v.append("слова с заглавной буквы подряд") }

        return v
    }

    private static func originalCapsRun(_ s: String) -> Int {
        var run = 0, best = 0
        for w in s.split(whereSeparator: \.isWhitespace) {
            if let f = w.first, f.isUppercase, w.count > 3 { run += 1; best = max(best, run) } else { run = 0 }
        }
        return best
    }
}
