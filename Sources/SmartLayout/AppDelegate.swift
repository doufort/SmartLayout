import AppKit
import ApplicationServices
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let store = WordStore()
    private lazy var engine = CorrectionEngine(store: store)
    private lazy var monitor = KeyboardMonitor(engine: engine, store: store)
    private var permissionTimer: Timer?
    private var running = false
    private lazy var ai = AIController(store: store)
    private let settingsWindow = SettingsWindowController()
    private var aiBusy = false
    private var flashMessage: String?
    private var flashWork: DispatchWorkItem?
    private var activity: NSObjectProtocol?
    private var watchdog: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Уже запущена другая копия (например, из автозапуска) — эта не нужна.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains(where: { $0 != NSRunningApplication.current }) {
            NSApp.terminate(nil)
            return
        }

        // Не даём macOS «усыплять» приложение (App Nap), чтобы реакция была мгновенной.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Отслеживание набора текста")

        // Автозапуск включаем один раз, при первом запуске; дальше — как выберете в меню.
        if !UserDefaults.standard.bool(forKey: "loginItemConfigured") {
            UserDefaults.standard.set(true, forKey: "loginItemConfigured")
            LoginItem.enable()
        }

        // После сна и периодически проверяем, что перехват клавиатуры включён.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.monitor.ensureEnabled()
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, self.running else { return }
            self.monitor.ensureEnabled()
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        rebuildMenu()
        updateTitle()

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(layoutChanged),
            name: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
            object: nil)

        monitor.onFix = { [weak self] _ in self?.updateTitle(); self?.rebuildMenu() }
        monitor.onTyped = { [weak self] ch in self?.ai.userTyped(ch) }
        monitor.onEscape = { [weak self] in self?.ai.cancel() }
        monitor.onParagraph = { [weak self] text in self?.ai.paragraphFinished(text) }
        ai.onBusy = { [weak self] busy in self?.aiBusy = busy; self?.updateTitle() }
        ai.onError = { [weak self] msg in self?.flash(msg) }
        ai.onApplied = { [weak self] in self?.monitor.reset() }
        ai.typedText = { [weak self] in self?.monitor.typedText ?? "" }
        ai.replaceTyped = { [weak self] count, text in self?.monitor.replaceTyped(count: count, with: text) }

        let mods = UInt32(optionKey | shiftKey)
        HotKeyCenter.shared.register(id: HotKeyID.fix, keyCode: UInt32(kVK_ANSI_F), modifiers: mods) { [weak self] in
            self?.ai.fixNow()
        }
        HotKeyCenter.shared.register(id: HotKeyID.improve, keyCode: UInt32(kVK_ANSI_I), modifiers: mods) { [weak self] in
            self?.ai.improveNow()
        }
        NotificationCenter.default.addObserver(forName: .smartLayoutSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildMenu()
        }
        installEditMenu()
        startWhenTrusted()
        if !AIConfig.current.isConfigured { settingsWindow.show() }
    }

    // MARK: Разрешения

    private func startWhenTrusted() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) && monitor.start() {
            running = true
            updateTitle()
            return
        }
        updateTitle()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self else { return }
            if AXIsProcessTrusted() && self.monitor.start() {
                t.invalidate()
                self.running = true
                self.updateTitle()
                self.rebuildMenu()
            }
        }
    }

    // MARK: Меню

    @objc private func layoutChanged() {
        DispatchQueue.main.async { self.monitor.refreshLayout(); self.updateTitle() }
    }

    private func updateTitle() {
        let lang = (InputSource.currentLanguage() ?? "--").uppercased()
        var title = running ? lang : "⚠︎ \(lang)"
        if aiBusy { title += " …" }
        if let msg = flashMessage { title += "  \(msg.prefix(60))" }
        statusItem.button?.title = title
    }

    /// Короткое сообщение в строке меню на несколько секунд.
    private func flash(_ message: String) {
        flashMessage = message
        updateTitle()
        flashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flashMessage = nil; self?.updateTitle() }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    /// Меню «Правка» нужно, чтобы в окне настроек работали Cmd+C / Cmd+V.
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выделить всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        if !running {
            menu.addItem(withTitle: "Нужен доступ: Универсальный доступ и Мониторинг ввода",
                         action: nil, keyEquivalent: "")
            menu.addItem(item("Открыть настройки доступа…", #selector(openPrivacy)))
            menu.addItem(.separator())
        }
        menu.addItem(toggle("Автопереключение раскладки", Settings.shared.autoSwitch, #selector(toggleAutoSwitch)))
        menu.addItem(toggle("Исправлять частые опечатки", Settings.shared.autocorrect, #selector(toggleAutocorrect)))
        menu.addItem(toggle("Угадывать исправления словарём macOS", Settings.shared.autocorrectGuess, #selector(toggleGuess)))
        menu.addItem(toggle("Отмена исправления по Backspace", Settings.shared.undoOnBackspace, #selector(toggleUndo)))
        menu.addItem(.separator())
        menu.addItem(item("Исправить текст (⌥⇧F)", #selector(fixText)))
        menu.addItem(item("Улучшить текст (⌥⇧I)", #selector(improveText)))
        menu.addItem(toggle("Проверка ИИ при паузе в наборе", Settings.shared.aiAutoCheck, #selector(toggleAICheck)))
        menu.addItem(toggle("Предлагать продолжение текста", Settings.shared.aiSuggestNext, #selector(toggleNext)))
        let memoryMenu = NSMenu()
        for m in [10.0, 30.0, 60.0] {
            let i = item("\(Int(m)) минут", #selector(setMemory(_:)))
            i.tag = Int(m)
            i.state = Settings.shared.memoryMinutes == m ? .on : .off
            memoryMenu.addItem(i)
        }
        memoryMenu.addItem(.separator())
        memoryMenu.addItem(item("Очистить память сейчас", #selector(clearMemory)))
        let memoryItem = NSMenuItem(title: "Память разговора: \(Int(Settings.shared.memoryMinutes)) мин", action: nil, keyEquivalent: "")
        memoryItem.submenu = memoryMenu
        menu.addItem(memoryItem)
        menu.addItem(item(AIConfig.current.isConfigured ? "Настройки ИИ…" : "Настроить ИИ… (не настроен)", #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(item("Мой словарь…", #selector(openUserWords)))
        menu.addItem(item("Перечитать словари", #selector(reloadWords)))
        menu.addItem(item("Сбросить исключения (\(store.exceptions.count))", #selector(clearExceptions)))
        menu.addItem(item("Забыть выученное (\(store.learning.learnedCount))", #selector(resetLearning)))
        menu.addItem(.separator())
        menu.addItem(toggle("Запускать при входе в систему", LoginItem.isEnabled, #selector(toggleLoginItem)))
        if LoginItem.needsApproval {
            menu.addItem(item("Разрешить автозапуск в «Объектах входа»…", #selector(openLoginItems)))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выход", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let i = item(title, action)
        i.state = on ? .on : .off
        return i
    }

    @objc private func toggleAutoSwitch() { Settings.shared.autoSwitch.toggle(); rebuildMenu() }
    @objc private func toggleGuess() { Settings.shared.autocorrectGuess.toggle(); rebuildMenu() }
    @objc private func toggleAutocorrect() { Settings.shared.autocorrect.toggle(); rebuildMenu() }
    @objc private func toggleUndo() { Settings.shared.undoOnBackspace.toggle(); rebuildMenu() }
    @objc private func toggleLoginItem() {
        if LoginItem.isEnabled || LoginItem.needsApproval { LoginItem.disable() } else { LoginItem.enable() }
        rebuildMenu()
        if LoginItem.needsApproval { LoginItem.openSettings() }
    }
    @objc private func openLoginItems() { LoginItem.openSettings() }
    @objc private func fixText() { ai.fixNow() }
    @objc private func improveText() { ai.improveNow() }
    @objc private func toggleNext() { Settings.shared.aiSuggestNext.toggle(); rebuildMenu() }
    @objc private func setMemory(_ sender: NSMenuItem) { Settings.shared.memoryMinutes = Double(sender.tag); rebuildMenu() }
    @objc private func clearMemory() { ai.memory.clear() }
    @objc private func toggleAICheck() { Settings.shared.aiAutoCheck.toggle(); rebuildMenu() }
    @objc private func openSettings() { settingsWindow.show() }
    @objc private func openUserWords() { NSWorkspace.shared.open(WordStore.userWordsURL) }
    @objc private func reloadWords() { store.reload(); engine.clearCaches(); rebuildMenu() }
    @objc private func resetLearning() {
        store.learning.reset(); ai.style.resetRecent(); engine.clearCaches(); rebuildMenu()
    }
    @objc private func clearExceptions() { store.clearExceptions(); rebuildMenu() }

    @objc private func openPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
