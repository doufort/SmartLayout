import AppKit
import ApplicationServices
import Carbon

/// Чтение и замена текста в активном поле другого приложения через Accessibility API.
struct FocusedText {
    let element: AXUIElement
    let value: String
    let selection: NSRange
}

enum TextAccess {
    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static var enabledPIDs = Set<pid_t>()

    /// Electron-приложения (Slack, Discord, VS Code, многие чаты) включают доступ к тексту
    /// только по запросу: просим их об этом один раз.
    static func enableManualAccessibility() {
        guard let app = NSWorkspace.shared.frontmostApplication, !enabledPIDs.contains(app.processIdentifier) else { return }
        enabledPIDs.insert(app.processIdentifier)
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Какое-то приложение включило защищённый ввод (поле пароля, sudo в терминале).
    /// Пока он включён, macOS не отдаёт нажатия перехватчику.
    static func secureInputActive() -> Bool { IsSecureEventInputEnabled() }

    /// Поле в фокусе — поле пароля (`AXSecureTextField`). Браузеры и Electron не всегда
    /// включают защищённый ввод, поэтому проверяем и сам элемент.
    static func isSecure(_ el: AXUIElement) -> Bool {
        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subrole) == .success else { return false }
        return (subrole as? String) == (kAXSecureTextFieldSubrole as String)
    }

    /// `timeout` ограничивает ожидание ответа от зависшего приложения: из обработчика
    /// нажатий нельзя ждать дольше доли секунды, иначе macOS отключит перехват.
    static func focusedIsSecure(timeout: Float = 0) -> Bool {
        let system = AXUIElementCreateSystemWide()
        if timeout > 0 { _ = AXUIElementSetMessagingTimeout(system, timeout) }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        let el = value as! AXUIElement
        if timeout > 0 { _ = AXUIElementSetMessagingTimeout(el, timeout) }
        return isSecure(el)
    }

    static func read() -> FocusedText? {
        enableManualAccessibility()
        guard let el = focusedElement(), !isSecure(el) else { return nil }
        var val: CFTypeRef?
        var rng: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &val) == .success,
              let text = val as? String,
              AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rng) == .success,
              let rng, CFGetTypeID(rng) == AXValueGetTypeID() else { return nil }
        var cf = CFRange()
        guard AXValueGetValue(rng as! AXValue, .cfRange, &cf) else { return nil }
        return FocusedText(element: el, value: text, selection: NSRange(location: cf.location, length: cf.length))
    }

    static func select(_ el: AXUIElement, range: NSRange) -> Bool {
        var cf = CFRange(location: range.location, length: range.length)
        guard let ax = AXValueCreate(.cfRange, &cf) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, ax) == .success
    }

    /// Заменяет диапазон текста. Если приложение не поддерживает запись через
    /// Accessibility (часто браузеры и Electron), вставляет через буфер обмена.
    static func replace(in el: AXUIElement, range: NSRange, with text: String) {
        guard select(el, range: range) else { Clipboard.paste(text); return }
        let ok = AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
        if ok, let after = read() {
            let ns = after.value as NSString
            let written = NSRange(location: range.location, length: (text as NSString).length)
            if NSMaxRange(written) <= ns.length, ns.substring(with: written) == text { return }
        }
        Clipboard.paste(text)
    }

    /// Положение курсора на экране (в координатах Cocoa), чтобы показать подсказку рядом.
    static func caretRect(_ el: AXUIElement, location: Int) -> NSRect? {
        var cf = CFRange(location: max(0, location - 1), length: location > 0 ? 1 : 0)
        guard let ax = AXValueCreate(.cfRange, &cf) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         ax, &out) == .success,
              let out, CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(out as! AXValue, .cgRect, &rect), rect.width + rect.height > 0 else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// Запасной путь через буфер обмена (Cmd+C / Cmd+V) с восстановлением содержимого.
enum Clipboard {
    /// Полная копия содержимого буфера: все элементы и все их типы (картинки, файлы, RTF),
    /// а не только текст. Иначе после исправления пропадает скопированная картинка.
    typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    static func snapshot(_ pb: NSPasteboard) -> Snapshot {
        (pb.pasteboardItems ?? []).map { item in
            var types = [NSPasteboard.PasteboardType: Data]()
            for t in item.types { if let d = item.data(forType: t) { types[t] = d } }
            return types
        }
    }

    static func restore(_ snapshot: Snapshot, to pb: NSPasteboard) {
        pb.clearContents()
        guard !snapshot.isEmpty else { return }
        let items: [NSPasteboardItem] = snapshot.map { types in
            let item = NSPasteboardItem()
            for (t, d) in types { item.setData(d, forType: t) }
            return item
        }
        pb.writeObjects(items)
    }

    static func paste(_ text: String, pasteboard pb: NSPasteboard = .general) {
        let saved = snapshot(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        let ours = pb.changeCount
        KeySender.chord(keyCode: 9, flags: .maskCommand) // Cmd+V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            // Если за это время вы сами что-то скопировали, не затираем.
            guard pb.changeCount == ours else { return }
            Clipboard.restore(saved, to: pb)
        }
    }

    /// Копирует выделенный текст активного приложения.
    static func copySelection(pasteboard pb: NSPasteboard = .general, completion: @escaping (String?) -> Void) {
        let saved = snapshot(pb)
        let before = pb.changeCount
        KeySender.chord(keyCode: 8, flags: .maskCommand) // Cmd+C
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            // Ничего не выделено — буфер не менялся, и трогать его не нужно.
            guard pb.changeCount != before else { completion(nil); return }
            let copied = pb.string(forType: .string)
            Clipboard.restore(saved, to: pb)
            completion(copied)
        }
    }
}
