import CoreGraphics

/// Отправка синтетических нажатий. Все события помечаются тегом,
/// чтобы наш же перехватчик их пропускал.
enum KeySender {
    static let syntheticTag: Int64 = 0x534C4159 // "SLAY"
    private static let source = CGEventSource(stateID: .privateState)

    private static func post(_ e: CGEvent?, flags: CGEventFlags = []) {
        guard let e else { return }
        e.flags = flags
        e.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
        e.post(tap: .cghidEventTap)
    }

    static func press(keyCode: CGKeyCode, keyUp: Bool = true) {
        post(CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true))
        if keyUp { post(CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)) }
    }

    static func backspace(times: Int) {
        guard times > 0 else { return }
        for _ in 0..<times { press(keyCode: 51) }
    }

    static func type(_ text: String) {
        for ch in text {
            var units = Array(String(ch).utf16)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            post(down)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            post(up)
        }
    }

    /// Сочетание клавиш, например Cmd+V.
    static func chord(keyCode: CGKeyCode, flags: CGEventFlags) {
        post(CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true), flags: flags)
        post(CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false), flags: flags)
    }
}
