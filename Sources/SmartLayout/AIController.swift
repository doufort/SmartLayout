import AppKit
import ApplicationServices

/// Этап 2: пунктуация, ошибки и улучшение текста через языковую модель.
/// - при паузе в наборе проверяет текущий абзац и показывает подсказку (ничего не меняет без вашего согласия);
/// - ⌥⇧F сразу исправляет выделенный текст (или всё поле);
/// - ⌥⇧I предлагает улучшенный вариант с пояснением.
final class AIController {
    private let client = AIClient()
    private let store: WordStore
    let style = StyleProfile()
    let memory = ConversationMemory()

    init(store: WordStore) { self.store = store }

    /// Абзац завершён клавишей Enter (часто это отправленное сообщение):
    /// запоминаем его в памяти разговора и как пример вашего стиля.
    func paragraphFinished(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2 else { return }
        memory.addMine(t, key: ConversationMemory.currentKey())
        style.addSample(t)
    }
    private let panel = SuggestionPanel()
    private var pending: DispatchWorkItem?
    private var typedSinceCheck = 0
    private var lastChecked = ""
    private var requestID = 0
    var onBusy: ((Bool) -> Void)?
    var onError: ((String) -> Void)?
    var onApplied: (() -> Void)?
    /// Текст, напечатанный подряд в текущем абзаце, и его замена (запасной путь,
    /// когда приложение не отдаёт содержимое поля).
    var typedText: (() -> String)?
    var replaceTyped: ((Int, String) -> Void)?

    // MARK: Автопроверка

    /// Вызывается на каждый напечатанный символ.
    func userTyped(_ ch: Character) {
        pending?.cancel()
        if panel.isVisible { panel.hide() }
        guard Settings.shared.aiAutoCheck, AIConfig.current.isConfigured else { return }
        typedSinceCheck += 1
        guard typedSinceCheck >= 10 else { return }
        let sentenceEnd = ".!?…\n".contains(ch)
        let delay = Settings.shared.aiPause * (sentenceEnd ? 0.6 : 1.0)
        let work = DispatchWorkItem { [weak self] in self?.autoCheck() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Esc: отменить запрос и отклонить показанную подсказку.
    func cancel() {
        pending?.cancel()
        requestID += 1
        panel.hide(rejected: true)
    }

    /// Сколько текста править за раз. Тесты показали, что на ~3000 символах модель обрезает ответ,
    /// поэтому правим последние ~700 символов (с начала предложения), а всё, что раньше, идёт как контекст.
    private let wholeTextLimit = 700

    /// Начало редактируемого куска: не раньше чем за `wholeTextLimit` до курсора и с начала предложения.
    private func editStart(in ns: NSString, caret: Int) -> Int {
        var start = max(0, caret - wholeTextLimit)
        guard start > 0 else { return 0 }
        let window = ns.substring(with: NSRange(location: start, length: caret - start)) as NSString
        let boundary = window.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?…\n"))
        if boundary.location != NSNotFound && boundary.location < window.length - 1 {
            start += boundary.location + 1
            while start < caret, let s = Unicode.Scalar(ns.character(at: start)), CharacterSet.whitespaces.contains(s) { start += 1 }
        }
        return start
    }

    private func autoCheck() {
        guard let field = TextAccess.read(), !field.value.isEmpty else { autoCheckTyped(); return }
        guard field.selection.length == 0 else { return }
        let ns = field.value as NSString
        let caret = field.selection.location
        guard caret <= ns.length else { return }

        // Текст поля до курсора: последние ~700 символов правим, остальное — контекст.
        let start = editStart(in: ns, caret: caret)
        let range = NSRange(location: start, length: caret - start)
        let text = ns.substring(with: range)
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8, text != lastChecked else { return }
        lastChecked = text
        typedSinceCheck = 0
        var ctx = context(before: start, in: ns)
        ctx.suggestNext = Settings.shared.aiSuggestNext

        request(.review, text: text, context: ctx) { [weak self] result in
            guard let self else { return }
            // Пока ждали ответ, текст могли изменить — тогда подсказка уже неактуальна.
            let stillSame: () -> Bool = {
                guard let now = TextAccess.read(), (now.value as NSString).length >= NSMaxRange(range) else { return false }
                return (now.value as NSString).substring(with: range) == text
            }
            guard stillSame() else { return }
            self.showReview(result, for: text, near: TextAccess.caretRect(field.element, location: caret),
                            stillSame: stillSame, insertNext: { next in
                                // Вставляем там, где стоит курсор, как будто напечатали сами.
                                self.replaceTyped?(0, next)
                            }) { newText in
                self.apply(newText, replacing: text, range: range, element: field.element)
            }
        }
    }

    /// Автопроверка по тому, что вы напечатали подряд (работает в любом приложении).
    private func autoCheckTyped() {
        guard let typed = typedText?() else { return }
        let typedNS = typed as NSString
        let text = typedNS.substring(from: editStart(in: typedNS, caret: typedNS.length))
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8, text != lastChecked else { return }
        lastChecked = text
        typedSinceCheck = 0
        var ctx = context(before: 0, in: "")
        ctx.previousText = String(typed.dropLast(text.count).suffix(1500))
        ctx.suggestNext = Settings.shared.aiSuggestNext

        request(.review, text: text, context: ctx) { [weak self] result in
            guard let self else { return }
            let stillSame: () -> Bool = { self.typedText?().hasSuffix(text) == true }
            guard stillSame() else { return }
            self.showReview(result, for: text, near: nil, stillSame: stillSame, insertNext: { next in
                self.replaceTyped?(0, next)
            }) { newText in
                self.lastChecked = ""
                self.replaceTyped?(text.count, newText)
            }
        }
    }

    /// Подсказка с двумя вариантами: исправленный (⌥↩) и альтернативный (⌥⇧↩).
    private func showReview(_ result: AIResult, for text: String, near rect: NSRect?,
                            stillSame: @escaping () -> Bool, insertNext: @escaping (String) -> Void,
                            replace: @escaping (String) -> Void) {
        let fixed = Self.keepEdgeWhitespace(result.text, like: text)
        let alternative = result.alternative.map { Self.keepEdgeWhitespace($0, like: text) }
        let fixedChanged = Self.normalized(fixed) != Self.normalized(text)
        let altUseful = alternative.map { Self.normalized($0) != Self.normalized(text) &&
                                          Self.normalized($0) != Self.normalized(fixed) } ?? false
        // Продолжение: добавляем пробел, если текст не заканчивается пробелом.
        let next: String? = result.next.map { n in
            let needsSpace = !(text.last?.isWhitespace ?? true)
            return (needsSpace ? " " : "") + n
        }
        guard fixedChanged || altUseful || next != nil else { return }

        var acceptNext: (() -> Void)? = nil
        if let n = next {
            acceptNext = {
                guard stillSame() else { self.onError?("Текст изменился."); return }
                self.lastChecked = ""
                insertNext(n)
            }
        }

        // Только продолжение, без правок.
        if !fixedChanged && !altUseful, let n = next {
            panel.show(title: "Дальше можно написать", suggestion: n.trimmingCharacters(in: .whitespaces),
                       note: nil, near: rect, primaryTitle: "Вставить  ⌥⇥") { acceptNext?() }
            return
        }

        let changes = LearningStore.wordChanges(from: text, to: fixed)
        let guarded: (String) -> Void = { newText in
            guard stillSame() else { self.onError?("Текст изменился, замена отменена."); return }
            replace(newText)
        }
        panel.show(title: fixedChanged ? "Исправленный текст" : "Ошибок нет. Можно сформулировать так:",
                   suggestion: fixedChanged ? fixed : (alternative ?? fixed),
                   alternative: fixedChanged && altUseful ? alternative : nil,
                   note: result.note, near: rect,
                   onReject: { self.store.learning.noteRejected(changes) },
                   onAcceptAlternative: altUseful && fixedChanged ? { guarded(alternative ?? fixed) } : nil,
                   next: next?.trimmingCharacters(in: .whitespaces), onAcceptNext: acceptNext) {
            if fixedChanged { self.store.learning.noteAccepted(changes) }
            let chosen = fixedChanged ? fixed : (alternative ?? fixed)
            self.style.addSample(chosen)
            guarded(chosen)
        }
    }

    // MARK: Горячие клавиши

    func fixNow() { runOnTarget(.fix) }
    func improveNow() { runOnTarget(.improve) }

    private func runOnTarget(_ mode: AIClient.Mode) {
        guard AIConfig.current.isConfigured else { onError?(AIError.notConfigured.localizedDescription); return }
        pending?.cancel()

        if let field = TextAccess.read(), !field.value.isEmpty {
            let ns = field.value as NSString
            var range = field.selection.length > 0 ? field.selection : NSRange(location: 0, length: ns.length)
            if range.length > 4000 { range = NSRange(location: NSMaxRange(range) - 4000, length: 4000) }
            let text = ns.substring(with: range)
            handle(mode, text: text, context: context(before: range.location, in: ns)) { [weak self] newText in
                self?.apply(newText, replacing: text, range: range, element: field.element)
            } near: { TextAccess.caretRect(field.element, location: NSMaxRange(range)) }
            return
        }

        // Приложение не отдаёт текст через Accessibility: работаем с выделением через буфер обмена.
        Clipboard.copySelection { [weak self] copied in
            guard let self else { return }
            guard let text = copied, !text.isEmpty else {
                // Ничего не выделено: берём напечатанное подряд.
                if let typed = self.typedText?(), typed.trimmingCharacters(in: .whitespaces).count >= 3 {
                    self.handle(mode, text: typed, context: self.context(before: 0, in: "")) { newText in
                        guard self.typedText?() == typed else { self.onError?("Текст изменился, замена отменена."); return }
                        self.replaceTyped?(typed.count, newText)
                    } near: { nil }
                } else {
                    self.onError?("Не удалось прочитать текст. Выделите его и нажмите сочетание ещё раз.")
                }
                return
            }
            self.handle(mode, text: text, context: self.context(before: 0, in: "")) { newText in
                Clipboard.paste(newText)
                self.onApplied?()
            } near: { nil }
        }
    }

    private func handle(_ mode: AIClient.Mode, text: String, context: AIClient.Context,
                        apply: @escaping (String) -> Void, near: @escaping () -> NSRect?) {
        request(mode, text: text, context: context) { [weak self] result in
            guard let self else { return }
            let newText = Self.keepEdgeWhitespace(result.text, like: text)
            if mode == .fix {
                if Self.normalized(newText) != Self.normalized(text) {
                    // Правку по горячей клавише вы запросили сами — считаем её принятой.
                    self.store.learning.noteAccepted(LearningStore.wordChanges(from: text, to: newText))
                    apply(newText)
                }
                else { self.onError?("Ошибок не найдено.") }
            } else {
                self.panel.show(title: "Улучшенный вариант", suggestion: newText, note: result.note,
                                near: near(), onReject: nil) { apply(newText) }
            }
        }
    }

    // MARK: Общее

    /// Контекст для модели: до 1500 символов перед фрагментом, приложение, словарь пользователя.
    private func context(before location: Int, in ns: NSString) -> AIClient.Context {
        var ctx = AIClient.Context()
        let start = max(0, location - 1500)
        if location > 0 && location <= ns.length {
            ctx.previousText = ns.substring(with: NSRange(location: start, length: location - start))
        }
        ctx.appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        ctx.glossary = store.glossaryForAI + style.words
        let key = ConversationMemory.currentKey()
        memory.captureScreen(key: key)   // обновится к следующей проверке
        ctx.conversation = memory.contextText(key: key)
        ctx.style = style.promptBlock()
        ctx.slang = store.words.union(store.learning.learnedWords)
        return ctx
    }

    private func request(_ mode: AIClient.Mode, text: String, context: AIClient.Context,
                         completion: @escaping (AIResult) -> Void) {
        requestID += 1
        let id = requestID
        onBusy?(true)
        Task {
            do {
                let result = try await client.run(mode, text: text, context: context)
                await MainActor.run {
                    self.onBusy?(false)
                    if id == self.requestID { completion(result) }
                }
            } catch {
                await MainActor.run {
                    self.onBusy?(false)
                    if id == self.requestID { self.onError?(error.localizedDescription) }
                }
            }
        }
    }

    private func apply(_ newText: String, replacing old: String, range: NSRange, element: AXUIElement) {
        // Ещё раз убеждаемся, что текст на месте.
        if let now = TextAccess.read(), (now.value as NSString).length >= NSMaxRange(range),
           (now.value as NSString).substring(with: range) != old {
            onError?("Текст изменился, замена отменена.")
            return
        }
        TextAccess.replace(in: element, range: range, with: newText)
        lastChecked = ""
        onApplied?()
    }

    private static func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Сохраняет пробелы и переносы по краям исходного текста.
    private static func keepEdgeWhitespace(_ s: String, like original: String) -> String {
        let core = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = original.prefix { $0.isWhitespace }
        let trail = String(original.reversed().prefix { $0.isWhitespace }.reversed())
        return String(lead) + core + trail
    }
}
