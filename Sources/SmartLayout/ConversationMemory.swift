import AppKit
import ApplicationServices

/// Память разговора: держит текст переписки в каждом окне заданное время
/// (по умолчанию 30 минут, меняется в настройках), чтобы модель не теряла мысль.
/// Хранится только в памяти и исчезает при выходе из приложения.
final class ConversationMemory {
    struct Entry {
        let date: Date
        let text: String
    }

    private var mine = [String: [Entry]]()        // ваши сообщения по окнам
    private var screen = [String: Entry]()        // последний снимок текста окна (сообщения собеседника и т.п.)
    private let queue = DispatchQueue(label: "smartlayout.memory")

    var minutes: Double { Settings.shared.memoryMinutes }

    /// Ключ окна: приложение + заголовок окна.
    static func currentKey() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "?" }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        var win: CFTypeRef?
        var title = ""
        if AXUIElementCopyAttributeValue(el, kAXFocusedWindowAttribute as CFString, &win) == .success,
           let win, CFGetTypeID(win) == AXUIElementGetTypeID() {
            var t: CFTypeRef?
            if AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &t) == .success {
                title = (t as? String) ?? ""
            }
        }
        return (app.bundleIdentifier ?? app.localizedName ?? "?") + "|" + title
    }

    func addMine(_ text: String, key: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        queue.sync {
            mine[key, default: []].append(Entry(date: Date(), text: t))
            prune()
        }
    }

    /// Снимает видимый текст активного окна (best effort, не дольше ~400 элементов).
    func captureScreen(key: String) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        DispatchQueue.global(qos: .utility).async {
            let el = AXUIElementCreateApplication(pid)
            var win: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXFocusedWindowAttribute as CFString, &win) == .success,
                  let win, CFGetTypeID(win) == AXUIElementGetTypeID() else { return }
            var texts: [String] = []
            var visited = 0
            Self.collect(win as! AXUIElement, depth: 0, visited: &visited, into: &texts)
            let joined = texts.joined(separator: "\n")
            let tail = String(joined.suffix(2500))
            guard !tail.isEmpty else { return }
            self.queue.sync { self.screen[key] = Entry(date: Date(), text: tail) }
        }
    }

    private static func collect(_ el: AXUIElement, depth: Int, visited: inout Int, into texts: inout [String]) {
        guard depth < 30, visited < 400 else { return }
        visited += 1
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        let r = (role as? String) ?? ""
        if r == kAXStaticTextRole as String || r == kAXTextAreaRole as String {
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success,
               let s = v as? String, s.count >= 2, s.count <= 3000 {
                texts.append(s)
            }
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return }
        for c in list { collect(c, depth: depth + 1, visited: &visited, into: &texts) }
    }

    /// Текст разговора для модели (до 3000 символов): экран + ваши сообщения за последние N минут.
    func contextText(key: String) -> String {
        queue.sync { () -> String in
            prune()
            var parts: [String] = []
            if let s = screen[key] { parts.append("Текст в окне (переписка, может включать сообщения собеседника):\n" + s.text) }
            let my = (mine[key] ?? []).map { $0.text }
            if !my.isEmpty { parts.append("Что автор уже написал в этом окне:\n" + my.joined(separator: "\n")) }
            let all = parts.joined(separator: "\n\n")
            return String(all.suffix(3000))
        }
    }

    func clear() { queue.sync { mine.removeAll(); screen.removeAll() } }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-minutes * 60)
        for (k, list) in mine {
            let kept = list.filter { $0.date > cutoff }
            mine[k] = kept.isEmpty ? nil : kept
        }
        for (k, e) in screen where e.date <= cutoff { screen[k] = nil }
    }
}
