import AppKit
import CoreGraphics

/// Перехватывает нажатия клавиш, собирает текущее слово и
/// на разделителе (пробел, Enter, Tab, знак препинания) исправляет его.
final class KeyboardMonitor {
    private enum Delimiter {
        case char(Character)   // пробел или знак, вводимый как текст
        case key(CGKeyCode)    // Enter / Tab — переотправляем как клавишу
        case none              // исправление посреди слова
    }

    private struct LastAction {
        let fix: Fix
        let insertedCount: Int
        let originalDelimiter: Delimiter
        let previousLayout: String
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var buffer = ""
    /// Всё, что напечатано подряд в текущем абзаце (до клика мышью, стрелок или Enter).
    /// Нужен для приложений, которые не отдают текст поля (Electron, некоторые сайты).
    private(set) var typedText = ""
    private var switchedAt: Date?           // когда мы сами переключили раскладку
    private var earlyDone = false          // раннее определение уже сработало для этого слова
    /// Текущая раскладка (кэш, обновляется при переключении).
    private(set) var layout = InputSource.currentLanguage() ?? "en"
    private var lastAction: LastAction?
    private let engine: CorrectionEngine
    private let store: WordStore
    var onFix: ((Fix) -> Void)?
    var onTyped: ((Character) -> Void)?   // любой напечатанный символ (для проверки ИИ при паузе)
    var onEscape: (() -> Void)?
    var onParagraph: ((String) -> Void)?   // абзац завершён клавишей Enter

    // Коды клавиш
    private let kBackspace: Int64 = 51, kReturn: Int64 = 36, kEnter: Int64 = 76, kTab: Int64 = 48
    private let resetKeys: Set<Int64> = [53, 117, 115, 119, 116, 121, 123, 124, 125, 126] // Esc, Del, Home, End, PgUp, PgDn, стрелки

    init(engine: CorrectionEngine, store: WordStore) {
        self.engine = engine
        self.store = store
    }

    @discardableResult
    func start() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Перехватчик мог отключиться (после сна, долгой нагрузки) — включаем снова.
    func ensureEnabled() {
        if let tap, !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func reset() {
        buffer = ""
        typedText = ""
        earlyDone = false
        lastAction = nil
    }

    private func typedReplaceTail(_ count: Int, with text: String) {
        if count > typedText.count { typedText = "" } else { typedText.removeLast(count) }
        typedText += text
        if typedText.count > 2000 { typedText = String(typedText.suffix(1500)) }
    }

    /// Заменяет последние `count` напечатанных символов (курсор должен стоять в конце набранного).
    func replaceTyped(count: Int, with text: String) {
        KeySender.backspace(times: count)
        KeySender.type(text)
        typedReplaceTail(count, with: text)
        buffer = ""
        earlyDone = false
        lastAction = nil
    }

    /// Вызывается при смене раскладки пользователем.
    func refreshLayout() {
        let current = InputSource.currentLanguage() ?? layout
        guard current != layout else { return }   // это наше же переключение
        layout = current
        buffer = ""
        earlyDone = false
        lastAction = nil
    }

    private func switchLayout(to lang: String) {
        if InputSource.select(language: lang) {
            layout = lang
            switchedAt = Date()
        }
    }

    private func isWordChar(_ c: Character, layout: String) -> Bool {
        if c.isLetter || c.isNumber || c == "-" { return true }
        if layout == "en" && LayoutMap.enKeysThatAreRuLetters.contains(c) { return true }
        return false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == KeySender.syntheticTag { return pass }
        if type == .leftMouseDown || type == .rightMouseDown { reset(); return pass }
        guard type == .keyDown else { return pass }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Сочетания с Cmd/Ctrl — это команды, а не текст.
        // Наши сочетания ⌥⇧F, ⌥⇧I и ⌥↩ не должны сбрасывать набранный текст.
        if flags.contains(.maskAlternate), !flags.contains(.maskCommand), !flags.contains(.maskControl),
           [3, 34, 36, 48].contains(keyCode) {
            return pass
        }
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            reset(); return pass
        }

        // Backspace: отмена последнего исправления или удаление символа из буфера.
        if keyCode == kBackspace {
            onTyped?("\u{8}")
            if Settings.shared.undoOnBackspace, let last = lastAction {
                lastAction = nil
                undo(last)
                return nil
            }
            lastAction = nil
            if !buffer.isEmpty { buffer.removeLast() }
            if !typedText.isEmpty { typedText.removeLast() }
            earlyDone = false
            return pass
        }
        lastAction = nil

        if keyCode == 53 { onEscape?() }
        if resetKeys.contains(keyCode) { reset(); return pass }

        if keyCode == kReturn || keyCode == kEnter || keyCode == kTab {
            let fixed = boundary(delimiter: .key(CGKeyCode(keyCode)), layout: layout)
            if keyCode != kTab, !typedText.isEmpty { onParagraph?(typedText) }
            typedText = ""          // новый абзац или переход в другое поле
            onTyped?("\n")
            return fixed ? nil : pass
        }

        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        guard length > 0, let ch = String(utf16CodeUnits: chars, count: length).last else { return pass }
        onTyped?(ch)

        // Быстрый набор: символы, нажатые до того, как macOS применила новую раскладку,
        // приходят ещё в старой. Переводим их на лету.
        if let t = switchedAt, Date().timeIntervalSince(t) < 0.7, let converted = lateCharFix(ch) {
            buffer.append(converted)
            typedReplaceTail(0, with: String(converted))
            KeySender.type(String(converted))
            return nil
        }

        if isWordChar(ch, layout: layout) {
            buffer.append(ch)
            typedReplaceTail(0, with: String(ch))
            if buffer.count > 64 { buffer = "" } // это уже не слово
            if !earlyDone, let fix = engine.evaluatePrefix(buffer, layout: layout) {
                earlyDone = true
                applyEarly(fix)
                return nil
            }
            return pass
        }
        if boundary(delimiter: .char(ch), layout: layout) { return nil }
        typedReplaceTail(0, with: String(ch))
        return pass
    }

    private func lateCharFix(_ ch: Character) -> Character? {
        if layout == "ru", CorrectionEngine.isEnLetter(ch) || LayoutMap.enKeysThatAreRuLetters.contains(ch) {
            return LayoutMap.enToRu[ch]
        }
        if layout == "en", CorrectionEngine.isRuLetter(ch) { return LayoutMap.ruToEn[ch] }
        return nil
    }

    /// Возвращает true, если исправление выполнено и исходное нажатие нужно поглотить.
    private func boundary(delimiter: Delimiter, layout: String) -> Bool {
        let token = buffer
        buffer = ""
        earlyDone = false
        guard !token.isEmpty, let fix = engine.evaluate(token: token, layout: layout) else { return false }

        KeySender.backspace(times: token.count)
        var text = fix.replacement
        if case .char(let c) = delimiter {
            text.append(fix.switchTo == "ru" ? LayoutMap.delimiterEnToRu(c) : c)
        }
        KeySender.type(text)
        if case .key(let code) = delimiter { KeySender.press(keyCode: code, keyUp: false) }
        if let lang = fix.switchTo { switchLayout(to: lang) }
        typedReplaceTail(token.count, with: text)

        // Отмена по Backspace — только если курсор остался в той же строке. Enter мог отправить
        // сообщение, а Tab — перевести фокус в другое поле: там Backspace стёр бы чужой текст.
        if case .char = delimiter {
            let inserted = fix.replacement.count + 1
            lastAction = LastAction(fix: fix, insertedCount: inserted, originalDelimiter: delimiter, previousLayout: layout)
        }
        onFix?(fix)
        return true
    }

    /// Исправление посреди слова: последний символ ещё не напечатан,
    /// поэтому стираем на один символ меньше и печатаем всё начало слова заново.
    private func applyEarly(_ fix: Fix) {
        let previous = layout
        KeySender.backspace(times: fix.original.count - 1)
        KeySender.type(fix.replacement)
        if let lang = fix.switchTo { switchLayout(to: lang) }
        typedReplaceTail(fix.original.count - 1, with: fix.replacement)
        buffer = fix.replacement
        lastAction = LastAction(fix: fix, insertedCount: fix.replacement.count,
                                originalDelimiter: .none, previousLayout: previous)
        onFix?(fix)
    }

    /// Backspace сразу после исправления: вернуть как было и запомнить слово как исключение.
    private func undo(_ last: LastAction) {
        KeySender.backspace(times: last.insertedCount)
        var text = last.fix.original
        if case .char(let c) = last.originalDelimiter { text.append(c) }
        KeySender.type(text)
        if case .key(let code) = last.originalDelimiter { KeySender.press(keyCode: code, keyUp: false) }
        typedReplaceTail(last.insertedCount, with: text)
        if last.fix.switchTo != nil { switchLayout(to: last.previousLayout) }
        store.addException(last.fix.original)
        if case .none = last.originalDelimiter {
            buffer = last.fix.original   // продолжаем то же слово в исходной раскладке
            earlyDone = true
        } else {
            buffer = ""
        }
    }
}
