import Foundation

/// Настройки подключения к языковой модели (любой сервис с OpenAI-совместимым API).
struct AIConfig {
    var baseURL: String
    var model: String
    var apiKey: String
    var folderID: String = ""   // только для Yandex Cloud

    static var current: AIConfig {
        AIConfig(baseURL: Settings.shared.aiBaseURL, model: Settings.shared.aiModel,
                 apiKey: Keychain.load(), folderID: Settings.shared.aiFolderID)
    }

    var isYandex: Bool { baseURL.contains("yandex") }

    /// Полное имя модели. Для Yandex: gpt://<ID каталога>/<модель>.
    var resolvedModel: String {
        if isYandex && !model.hasPrefix("gpt://") && !folderID.isEmpty { return "gpt://\(folderID)/\(model)" }
        return model
    }

    /// Модель на этом Mac или в домашней сети (Ollama и т.п.): текст не уходит в интернет.
    var isLocal: Bool { Self.isLocalHost(URL(string: baseURL)?.host) }

    static func isLocalHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased(), !h.isEmpty else { return false }
        if h == "localhost" || h == "::1" || h.hasSuffix(".local") { return true }
        let p = h.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return p[0] == 127 || p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1]))
    }

    /// Ключ нельзя отправлять открытым текстом в интернет.
    var sendsKeyInsecurely: Bool {
        !apiKey.isEmpty && baseURL.lowercased().hasPrefix("http://") && !isLocal
    }

    /// Название сервиса для сообщений пользователю.
    var providerName: String {
        Self.presets.first { !$0.url.isEmpty && baseURL.hasPrefix($0.url) }?.name ?? (URL(string: baseURL)?.host ?? baseURL)
    }

    /// Ключ не нужен только для локальной модели (Ollama и т.п.).
    var isConfigured: Bool {
        guard !baseURL.isEmpty, !model.isEmpty else { return false }
        if isYandex && !model.hasPrefix("gpt://") && folderID.isEmpty { return false }
        return isLocal || !apiKey.isEmpty
    }

    struct Preset { let name: String; let url: String; let model: String }
    /// Названия моделей можно поменять в настройках: актуальные смотрите на сайте сервиса.
    static let presets: [Preset] = [
        Preset(name: "OpenAI", url: "https://api.openai.com/v1", model: "gpt-4o-mini"),
        Preset(name: "xAI (Grok)", url: "https://api.x.ai/v1", model: "grok-3-mini"),
        Preset(name: "YandexGPT", url: "https://llm.api.cloud.yandex.net/v1", model: "yandexgpt/latest"),
        Preset(name: "Ollama (локально, бесплатно)", url: "http://localhost:11434/v1", model: "qwen2.5:7b"),
        Preset(name: "Свой адрес", url: "", model: "")
    ]
}

enum AIError: LocalizedError {
    case notConfigured
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "ИИ не настроен: откройте настройки и укажите ключ (и каталог для Yandex)"
        case .badResponse(let why): return "Ошибка ИИ: \(why)"
        }
    }
}

struct AIResult {
    let text: String            // исправленный текст (fix/review) или улучшенный (improve)
    let note: String?
    var alternative: String? = nil   // альтернативный вариант (review)
    var next: String? = nil          // что можно написать дальше (review)
    /// Вариант формулировки нарушил правило «не похоже на нейросеть». Исправленный текст
    /// показывается сразу, а переписанный вариант догружается в фоне (`rewriteAlternative`).
    var rewrite: Rewrite? = nil

    struct Rewrite {
        let messages: [[String: String]]   // разговор с моделью, включая просьбу переписать
        let original: String
        let slang: Set<String>
    }
}

/// Последние ответы модели: если текст тот же (стёрли и набрали заново), ответ мгновенный и бесплатный.
struct AIResultCache {
    let capacity: Int
    let ttl: TimeInterval
    private var items: [String: (date: Date, result: AIResult)] = [:]
    private var order: [String] = []

    init(capacity: Int = 64, ttl: TimeInterval = 600) {
        self.capacity = capacity
        self.ttl = ttl
    }

    static func key(_ mode: AIClient.Mode, _ text: String, suggestNext: Bool) -> String {
        "\(mode)|\(suggestNext)|\(text)"
    }

    mutating func get(_ key: String, now: Date = Date()) -> AIResult? {
        guard let item = items[key] else { return nil }
        guard now.timeIntervalSince(item.date) < ttl else { items[key] = nil; return nil }
        return item.result
    }

    mutating func put(_ key: String, _ result: AIResult, now: Date = Date()) {
        if items[key] == nil { order.append(key) }
        items[key] = (now, result)
        while order.count > capacity { items[order.removeFirst()] = nil }
    }

    var count: Int { items.count }
}

final class AIClient {
    enum Mode { case fix, review, improve }

    private static let fixPrompt = """
    Ты корректор. Исправь в тексте пользователя орфографию, пунктуацию, грамматику и заглавные буквы. \
    Текст может быть на русском, английском или смешанным, отвечай на том же языке. \
    Не меняй смысл, стиль и порядок слов, ничего не добавляй и не убирай. \
    Сленг, мат, сокращения, англицизмы и интернет-лексика (кринж, норм, спс, имхо, лол и т.п.) допустимы: \
    не заменяй их литературными словами, исправляй в них только явные опечатки. \
    Учитывай смысл всего текста и предыдущий контекст: если слово явно не подходит по смыслу \
    (компания/кампания, одеть/надеть, -тся/-ться, тоже/то же, не/ни), исправь его. \
    Обязательно: заглавная буква в начале каждого предложения, запятые между частями сложного предложения \
    и перед обращениями, вводными словами и союзами «что», «но», «а», точка или другой знак в конце законченного предложения. \
    Не ставь длинное тире там, где достаточно запятой, и не добавляй разметку. \
    Если ошибок нет, верни текст без изменений. Верни только исправленный текст, без кавычек и пояснений.
    Пример. Вход: привет как дела я тут подумал что надо встретится
    Выход: Привет, как дела? Я тут подумал, что надо встретиться.
    """

    private static let reviewPrompt = """
    Ты корректор и редактор. Проверь весь текст пользователя целиком, с учётом смысла и предыдущего контекста. \
    Текст может быть на русском, английском или смешанным, отвечай на том же языке. \
    Сленг, сокращения, разговорные формы и интернет-лексика (пж, чё, чет = что-то, щас, норм, баг, скрин) \
    сохраняй как есть в ОБОИХ вариантах, не заменяй их литературными словами и не «исправляй» на похожие слова.
    Верни строго JSON: {"fixed": "...", "alternative": "...", "note": "..."}
    fixed: тот же текст с исправленными орфографией, пунктуацией, грамматикой и заглавными буквами. \
    Слова и их порядок не меняй, кроме явных ошибок и слов, не подходящих по смыслу (компания/кампания, одеть/надеть, -тся/-ться, тоже/то же, не/ни).
    alternative: другой вариант того же текста, максимально близкий по смыслу и тону автора, с более ясным построением фраз \
    и безупречной пунктуацией. Сохрани все утверждения автора: ничего не убирай, не добавляй и не меняй смысл. \
    Меняй только построение фраз и порядок слов. Если исходник и так хорошо построен, alternative равен fixed.
    note: одна короткая фраза о главном изменении на языке текста, или пустая строка.
    next: только если пользователь просит продолжение. Короткая следующая фраза (до 15 слов), которую автор, \
    скорее всего, напишет дальше по смыслу разговора, его словами и в его стиле, с его сленгом. \
    Начинается так, чтобы её можно было дописать сразу после текста. Если продолжение неочевидно, пустая строка.
    alternative и next пиши так, как написал бы сам автор: опирайся на его стиль и примеры, а не на «правильный» шаблон.
    Пример. Вход: короче я вчера посмотрел твой отчет там вроде все норм но графики не понятные какието
    Ответ: {"fixed": "Короче, я вчера посмотрел твой отчёт, там вроде всё норм, но графики непонятные какие-то.", \
    "alternative": "Короче, вчера посмотрел твой отчёт. В целом всё норм, только графики какие-то непонятные.", \
    "note": "Расставлены запятые, «непонятные» и «какие-то» исправлены.", \
    "next": "Можешь их переделать до пятницы?"}
    """ + "\n" + HumanStyle.rules

    private static let improvePrompt = """
    Ты редактор. Сделай текст пользователя понятнее, грамотнее и естественнее, сохранив смысл, язык и тон. \
    Учитывай предыдущий контекст и приложение (в мессенджере текст разговорный, в почте деловой). \
    Сленг оставляй, если он уместен по тону. \
    Исправь ошибки и пунктуацию, убери повторы и неудачные обороты. Если смысл фразы неясен или противоречив, \
    выбери наиболее вероятный и кратко отметь это. \
    Ответь строго в формате JSON: {"text": "улучшенный текст", "note": "одно короткое пояснение, что изменено, на языке текста"}.
    """ + "\n" + HumanStyle.rules

    /// Что ещё известно о тексте, чтобы модель понимала смысл.
    struct Context {
        var previousText: String = ""     // текст перед исправляемым фрагментом
        var appName: String = ""          // в каком приложении печатают
        var glossary: [String] = []       // словарь и сленг пользователя
        var slang: Set<String> = []        // все известные сленговые слова (для проверки варианта)
        var styleProfile: String = ""      // описание стиля и примеры из анкеты: не меняется
        var styleRecent: String = ""       // свежие тексты автора: меняются
        var conversation: String = ""      // память разговора в этом окне
        var suggestNext: Bool = false      // нужно ли предлагать продолжение
    }

    /// Системное сообщение: инструкция и постоянный профиль стиля. Оно одинаковое от запроса
    /// к запросу, поэтому провайдер (OpenAI и др.) кэширует его — запрос быстрее и дешевле.
    static func systemMessage(_ mode: Mode, _ ctx: Context) -> String {
        let prompt: String
        switch mode {
        case .fix: prompt = fixPrompt
        case .review: prompt = reviewPrompt
        case .improve: prompt = improvePrompt
        }
        return ctx.styleProfile.isEmpty ? prompt : prompt + "\n\n" + ctx.styleProfile
    }

    /// Сообщение пользователя: от более постоянного к меняющемуся, текст для правки — в конце.
    static func userMessage(_ text: String, _ ctx: Context) -> String {
        var parts: [String] = []
        if !ctx.glossary.isEmpty {
            parts.append("Слова пользователя (его сленг и термины, считать правильными и не менять): " +
                         ctx.glossary.joined(separator: ", "))
        }
        if !ctx.appName.isEmpty { parts.append("Приложение: \(ctx.appName)") }
        if !ctx.styleRecent.isEmpty { parts.append(ctx.styleRecent) }
        if !ctx.conversation.isEmpty {
            parts.append("Память разговора (последние минуты), только для понимания (НЕ исправлять и НЕ выводить):\n<<<\n\(ctx.conversation)\n>>>")
        }
        if ctx.suggestNext { parts.append("Предложи продолжение (поле next).") }
        if !ctx.previousText.isEmpty {
            parts.append("Предыдущий текст, только для понимания смысла (НЕ исправлять и НЕ выводить):\n<<<\n\(ctx.previousText)\n>>>")
        }
        if parts.isEmpty { return text }
        parts.append("Текст для обработки:\n<<<\n\(text)\n>>>")
        return parts.joined(separator: "\n\n")
    }

    func run(_ mode: Mode, text: String, context: Context = Context(),
             config: AIConfig = .current) async throws -> AIResult {
        guard config.isConfigured else { throw AIError.notConfigured }
        var messages: [[String: String]] = [
            ["role": "system", "content": Self.systemMessage(mode, context)],
            ["role": "user", "content": Self.userMessage(text, context)]
        ]

        // До двух попыток: если вариант нарушает правило естественного текста, просим переписать.
        for attempt in 0..<2 {
            let content = try await complete(messages: messages, config: config)
            var result: AIResult
            switch mode {
            case .fix: result = AIResult(text: Self.strip(Self.clean(content)), note: nil)
            case .review, .improve:
                // Обрезанный или битый JSON нельзя показывать как «исправленный текст»:
                // иначе по ⌥↩ в поле вставится {"fixed": "...
                guard let parsed = mode == .review ? Self.parseReview(content) : Self.parseImprove(content) else {
                    throw AIError.badResponse("модель вернула неполный ответ")
                }
                result = parsed
            }
            if mode == .fix || mode == .review {
                // Защита: правка не должна быть сильно длиннее исходника (модель захватила контекст).
                if result.text.count > text.count * 2 + 40 { throw AIError.badResponse("ответ не похож на правку") }
                // И не должна быть сильно короче: модель иногда обрезает длинный текст. Такую правку не предлагаем.
                if Double(result.text.count) < Double(text.count) * 0.8 - 10 {
                    throw AIError.badResponse("модель вернула обрезанный текст")
                }
            }
            if mode == .fix { return result }

            let checked = mode == .review ? (result.alternative ?? "") : result.text
            var problems = checked.isEmpty ? [] : HumanStyle.violations(in: checked, original: text, slang: context.slang)
            // Продолжение тоже проверяем (сравниваем со стилем исходника, длину не учитываем).
            if mode == .review, let next = result.next {
                let nextProblems = HumanStyle.violations(in: next, original: text + " " + next, slang: [])
                if !nextProblems.isEmpty { result.next = nil }
            }
            if problems.isEmpty { return result }
            problems = Array(problems.prefix(6))
            let retry = messages + [
                ["role": "assistant", "content": content],
                ["role": "user", "content":
                    "В варианте нарушены правила естественного текста: \(problems.joined(separator: "; ")). " +
                    "Перепиши, строго соблюдая все правила. Формат ответа тот же."]
            ]
            // Подсказка при паузе: исправленный текст не ждёт второго запроса,
            // вариант формулировки догрузится в фоне.
            if mode == .review {
                result.alternative = nil
                result.rewrite = AIResult.Rewrite(messages: retry, original: text, slang: context.slang)
                return result
            }
            if attempt == 0 {
                messages = retry
                continue
            }
            // Вторая попытка тоже не прошла: такой вариант не показываем.
            if mode == .review { result.alternative = nil; return result }
            throw AIError.badResponse("вариант похож на сгенерированный, попробуйте ещё раз")
        }
        throw AIError.badResponse("нет ответа")
    }

    /// Второй запрос для варианта формулировки: nil, если и он нарушает правила.
    func rewriteAlternative(_ rewrite: AIResult.Rewrite, config: AIConfig = .current) async throws -> String? {
        let content = try await complete(messages: rewrite.messages, config: config)
        guard let parsed = Self.parseReview(content), let alt = parsed.alternative,
              HumanStyle.violations(in: alt, original: rewrite.original, slang: rewrite.slang).isEmpty else { return nil }
        return alt
    }

    /// Открыть соединение с сервисом заранее (без ключа и без текста): первая подсказка
    /// не тратит время на установку защищённого соединения.
    static func warmUp(_ config: AIConfig) {
        guard config.isConfigured, !config.isLocal, let url = URL(string: config.baseURL),
              let scheme = url.scheme, let host = url.host,
              let root = URL(string: "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")/") else { return }
        var req = URLRequest(url: root, timeoutInterval: 10)
        req.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }

    private func complete(messages: [[String: String]], config: AIConfig) async throws -> String {
        guard !config.sendsKeyInsecurely else {
            throw AIError.badResponse("ключ не отправляется по http:// — укажите адрес https://")
        }
        let base = config.baseURL.hasSuffix("/") ? String(config.baseURL.dropLast()) : config.baseURL
        guard let url = URL(string: base + "/chat/completions") else { throw AIError.notConfigured }

        var req = URLRequest(url: url, timeoutInterval: 25)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            // Yandex Cloud принимает API-ключ в формате "Api-Key <ключ>".
            let auth = config.isYandex ? "Api-Key \(config.apiKey)" : "Bearer \(config.apiKey)"
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        if config.isYandex && !config.folderID.isEmpty {
            req.setValue(config.folderID, forHTTPHeaderField: "x-folder-id")
        }
        let body: [String: Any] = ["model": config.resolvedModel, "temperature": 0.2, "messages": messages]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AIError.badResponse("HTTP \(status) \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIError.badResponse("неожиданный ответ")
        }
        return content
    }

    /// Убирает разметку <<< >>>, которую модель иногда повторяет.
    private static func strip(_ s: String) -> String {
        s.replacingOccurrences(of: "<<<", with: "").replacingOccurrences(of: ">>>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func jsonObject(_ content: String) -> [String: Any]? {
        let t = clean(content)
        guard let start = t.firstIndex(of: "{"), let end = t.lastIndex(of: "}"),
              let data = String(t[start...end]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Похоже ли на попытку ответить JSON (тогда текст как есть показывать нельзя).
    static func looksLikeJSON(_ content: String) -> Bool {
        let t = clean(content)
        return t.hasPrefix("{") || t.contains("\"fixed\"") || t.contains("\"text\"")
    }

    static func parseReview(_ content: String) -> AIResult? {
        guard let obj = jsonObject(content), let fixed = obj["fixed"] as? String else {
            if looksLikeJSON(content) { return nil }
            return AIResult(text: strip(clean(content)), note: nil)
        }
        let alt = (obj["alternative"] as? String).map(strip)
        let note = (obj["note"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let fixedClean = strip(fixed)
        let useAlt = alt.flatMap { $0.isEmpty || $0 == fixedClean ? nil : $0 }
        let next = (obj["next"] as? String).map(strip).flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
        return AIResult(text: fixedClean, note: note, alternative: useAlt, next: next)
    }

    private static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if t.hasSuffix("```") { t = String(t.dropLast(3)) }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }

    static func parseImprove(_ content: String) -> AIResult? {
        if let obj = jsonObject(content), let text = obj["text"] as? String {
            let note = (obj["note"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return AIResult(text: strip(text), note: note)
        }
        if looksLikeJSON(content) { return nil }
        return AIResult(text: strip(clean(content)), note: nil)
    }
}
