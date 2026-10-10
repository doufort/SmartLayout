import Foundation

/// Настройки приложения (хранятся в UserDefaults).
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "autoSwitch": true,
            "autocorrect": true,
            "undoOnBackspace": true,
            "autocorrectGuess": false,
            "aiAutoCheck": true,
            "aiSuggestNext": true,
            "memoryMinutes": 30.0,
            "aiPause": 1.5,
            "aiBaseURL": "https://api.openai.com/v1",
            "aiModel": "gpt-4o-mini"
        ])
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
}
