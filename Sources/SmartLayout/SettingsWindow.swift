import AppKit

/// Окно настроек ИИ: сервис, адрес, модель, ключ.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let providerPopup = NSPopUpButton()
    private let urlField = NSTextField()
    private let modelField = NSTextField()
    private let keyField = NSSecureTextField()
    private let folderField = NSTextField()
    private let autoCheckBox = NSButton(checkboxWithTitle: "Проверять пунктуацию и ошибки при паузе в наборе", target: nil, action: nil)
    private let pauseField = NSTextField()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let client = AIClient()

    func show() {
        if window == nil { build() }
        load()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "SmartLayout — настройки ИИ"
        w.isReleasedWhenClosed = false
        w.delegate = self

        for p in AIConfig.presets { providerPopup.addItem(withTitle: p.name) }
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        urlField.placeholderString = "https://api.openai.com/v1"
        modelField.placeholderString = "название модели"
        keyField.placeholderString = "API-ключ (для Ollama не нужен)"
        folderField.placeholderString = "ID каталога Yandex Cloud (b1g…), только для YandexGPT"
        pauseField.placeholderString = "1.5"
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.preferredMaxLayoutWidth = 480

        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.alignment = .right
            return l
        }
        let grid = NSGridView(views: [
            [label("Сервис:"), providerPopup],
            [label("Адрес API:"), urlField],
            [label("Модель:"), modelField],
            [label("Ключ:"), keyField],
            [label("Каталог:"), folderField],
            [label("Пауза, сек:"), pauseField],
            [NSGridCell.emptyContentView, autoCheckBox]
        ])
        grid.column(at: 1).width = 360
        grid.rowSpacing = 10

        let test = NSButton(title: "Проверить соединение", target: self, action: #selector(testTapped))
        let save = NSButton(title: "Сохранить", target: self, action: #selector(saveTapped))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [test, save])

        let stack = NSStackView(views: [grid, statusLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        w.contentView = stack
        window = w
    }

    private func load() {
        let s = Settings.shared
        urlField.stringValue = s.aiBaseURL
        modelField.stringValue = s.aiModel
        keyField.stringValue = Keychain.load()
        folderField.stringValue = s.aiFolderID
        pauseField.stringValue = String(s.aiPause)
        autoCheckBox.state = s.aiAutoCheck ? .on : .off
        let idx = AIConfig.presets.firstIndex { !$0.url.isEmpty && $0.url == s.aiBaseURL } ?? AIConfig.presets.count - 1
        providerPopup.selectItem(at: idx)
        statusLabel.stringValue = "Текст, который проверяется, отправляется выбранному сервису. Для полной приватности используйте Ollama на своём Mac."
    }

    @objc private func providerChanged() {
        let p = AIConfig.presets[providerPopup.indexOfSelectedItem]
        guard !p.url.isEmpty else { return }
        urlField.stringValue = p.url
        modelField.stringValue = p.model
    }

    private var formConfig: AIConfig {
        AIConfig(baseURL: urlField.stringValue.trimmingCharacters(in: .whitespaces),
                 model: modelField.stringValue.trimmingCharacters(in: .whitespaces),
                 apiKey: keyField.stringValue.trimmingCharacters(in: .whitespaces),
                 folderID: folderField.stringValue.trimmingCharacters(in: .whitespaces))
    }

    @objc private func saveTapped() {
        let c = formConfig
        let s = Settings.shared
        s.aiBaseURL = c.baseURL
        s.aiModel = c.model
        s.aiFolderID = c.folderID
        Keychain.save(c.apiKey)
        s.aiPause = max(0.5, Double(pauseField.stringValue.replacingOccurrences(of: ",", with: ".")) ?? 1.5)
        s.aiAutoCheck = autoCheckBox.state == .on
        statusLabel.stringValue = "Сохранено."
        NotificationCenter.default.post(name: .smartLayoutSettingsChanged, object: nil)
    }

    @objc private func testTapped() {
        statusLabel.stringValue = "Проверяю…"
        let config = formConfig
        Task {
            do {
                let r = try await client.run(.fix, text: "здравствуйте коллеги я посмотрел отчет и думаю что нам стоит обсудить его завтра", config: config)
                await MainActor.run { self.statusLabel.stringValue = "Работает. Ответ модели: \(r.text)" }
            } catch {
                await MainActor.run { self.statusLabel.stringValue = error.localizedDescription }
            }
        }
    }
}

extension Notification.Name {
    static let smartLayoutSettingsChanged = Notification.Name("SmartLayoutSettingsChanged")
}
