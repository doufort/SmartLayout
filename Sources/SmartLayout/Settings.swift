import Foundation

/// Настройки приложения (хранятся в UserDefaults).
final class Settings {
    static let shared = Settings()
    private let d: UserDefaults

    /// `defaults` подменяется в тестах.
    init(defaults: UserDefaults = .standard) {
        d = defaults
        migratePrivacyDefaults()
        d.register(defaults: [
            "autoSwitch": true,
            "autocorrect": true,
            "undoOnBackspace": true,
            "autocorrectGuess": false,
            // Отправлять текст ИИ можно только с явного согласия: в новой установке выключено.
            "aiAutoCheck": false,
            "aiReadWindow": false,
            "aiSuggestNext": true,
            "memoryMinutes": 30.0,
            "aiPause": 1.5,
            "aiBaseURL": "https://api.openai.com/v1",
            "aiModel": "gpt-4o-mini"
        ])
    }

    /// Версия 1.0 по умолчанию проверяла текст ИИ при паузе и читала текст окна.
    /// У тех, кто уже пользовался приложением, сохраняем это поведение явно,
    /// а в новой установке обе настройки выключены. Вызывается до `register(defaults:)`,
    /// чтобы `object(forKey:)` видел только сохранённые значения.
    private func migratePrivacyDefaults() {
        guard d.object(forKey: "privacyMigrated") == nil else { return }
        d.set(true, forKey: "privacyMigrated")
        guard d.object(forKey: "loginItemConfigured") != nil else { return }   // новая установка
        if d.object(forKey: "aiAutoCheck") == nil { d.set(true, forKey: "aiAutoCheck") }
        if d.object(forKey: "aiReadWindow") == nil { d.set(true, forKey: "aiReadWindow") }
    }

    /// Автопереключение раскладки и исправление набранного слова.
    var autoSwitch: Bool {
        get { d.bool(forKey: "autoSwitch") }
        set { d.set(newValue, forKey: "autoSwitch") }
    }

    /// Автоисправление орфографических ошибок.
    var autocorrect: Bool {
        get { d.bool(forKey: "autocorrect") }
        set { d.set(newValue, forKey: "autocorrect") }
    }

    /// Молча исправлять незнакомые слова по догадке словаря macOS.
    /// Выключено по умолчанию: такие замены часто ломают сленг и намеренные написания,
    /// а исправления от ИИ всё равно показываются подсказкой.
    var autocorrectGuess: Bool {
        get { d.bool(forKey: "autocorrectGuess") }
        set { d.set(newValue, forKey: "autocorrectGuess") }
    }

    /// Backspace сразу после исправления возвращает исходный текст.
    var undoOnBackspace: Bool {
        get { d.bool(forKey: "undoOnBackspace") }
        set { d.set(newValue, forKey: "undoOnBackspace") }
    }

    /// Проверка ИИ (пунктуация, ошибки) при паузе в наборе.
    var aiAutoCheck: Bool {
        get { d.bool(forKey: "aiAutoCheck") }
        set { d.set(newValue, forKey: "aiAutoCheck") }
    }

    /// Пауза в наборе (секунды), после которой запускается проверка ИИ.
    var aiPause: Double {
        get { d.double(forKey: "aiPause") }
        set { d.set(newValue, forKey: "aiPause") }
    }

    var aiBaseURL: String {
        get { d.string(forKey: "aiBaseURL") ?? "" }
        set { d.set(newValue, forKey: "aiBaseURL") }
    }

    /// Передавать ИИ видимый текст окна (переписку, включая сообщения собеседника).
    var aiReadWindow: Bool {
        get { d.bool(forKey: "aiReadWindow") }
        set { d.set(newValue, forKey: "aiReadWindow") }
    }

    /// Предлагать продолжение текста.
    var aiSuggestNext: Bool {
        get { d.bool(forKey: "aiSuggestNext") }
        set { d.set(newValue, forKey: "aiSuggestNext") }
    }

    /// Сколько минут держать в памяти текст разговора.
    var memoryMinutes: Double {
        get { d.double(forKey: "memoryMinutes") }
        set { d.set(newValue, forKey: "memoryMinutes") }
    }

    var aiFolderID: String {
        get { d.string(forKey: "aiFolderID") ?? "" }
        set { d.set(newValue, forKey: "aiFolderID") }
    }

    var aiModel: String {
        get { d.string(forKey: "aiModel") ?? "" }
        set { d.set(newValue, forKey: "aiModel") }
    }

    /// Сочетания «Исправить» и «Улучшить»: ⌃⌥F/⌃⌥I вместо ⌥⇧F/⌥⇧I.
    /// ⌥⇧F и ⌥⇧I в раскладке U.S. печатают «Ï» и «ˆ», и пока работает SmartLayout, их не набрать.
    var hotkeyControlOption: Bool {
        get { d.bool(forKey: "hotkeyControlOption") }
        set { d.set(newValue, forKey: "hotkeyControlOption") }
    }

    /// Модификаторы для подписи в меню.
    var hotkeyLabel: String { hotkeyControlOption ? "⌃⌥" : "⌥⇧" }

    /// Приложения, которые вы сами исключили (bundle id).
    var excludedApps: Set<String> {
        get { Set(d.stringArray(forKey: "excludedApps") ?? []) }
        set { d.set(newValue.sorted(), forKey: "excludedApps") }
    }

    /// Приложения из списка исключений по умолчанию, которые вы включили обратно.
    var allowedApps: Set<String> {
        get { Set(d.stringArray(forKey: "allowedApps") ?? []) }
        set { d.set(newValue.sorted(), forKey: "allowedApps") }
    }
}
