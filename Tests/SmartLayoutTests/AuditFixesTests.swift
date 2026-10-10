import Carbon
import XCTest
@testable import SmartLayout

/// Тесты на закрытые пункты docs/AUDIT.md (#3–#10).
final class AppExclusionsTests: XCTestCase {
    func testTerminalsEditorsAndPasswordManagersExcludedByDefault() {
        for id in ["com.apple.Terminal", "com.googlecode.iterm2", "com.microsoft.VSCode",
                   "com.jetbrains.intellij", "com.jetbrains.pycharm", "com.1password.1password", "com.bitwarden.desktop"] {
            XCTAssertTrue(AppExclusions.isExcluded(id, userExcluded: [], userAllowed: []), id)
        }
        for id in ["ru.keepcoder.Telegram", "com.apple.Notes", "com.apple.mail", "com.tinyspeck.slackmacgap"] {
            XCTAssertFalse(AppExclusions.isExcluded(id, userExcluded: [], userAllowed: []), id)
        }
        XCTAssertFalse(AppExclusions.isExcluded(nil, userExcluded: [], userAllowed: []))
    }

    func testUserChoicesOverrideDefaultsButNotPasswordManagers() {
        XCTAssertFalse(AppExclusions.isExcluded("com.apple.Terminal", userExcluded: [], userAllowed: ["com.apple.Terminal"]))
        XCTAssertTrue(AppExclusions.isExcluded("com.apple.Notes", userExcluded: ["com.apple.Notes"], userAllowed: []))
        XCTAssertTrue(AppExclusions.isExcluded("com.1password.1password", userExcluded: [],
                                               userAllowed: ["com.1password.1password"]))
    }

    func testToggle() {
        let settings = Settings(defaults: TestFiles.defaults())
        AppExclusions.toggle("com.apple.Notes", settings: settings)
        XCTAssertTrue(AppExclusions.isExcluded("com.apple.Notes", settings: settings))
        AppExclusions.toggle("com.apple.Notes", settings: settings)
        XCTAssertFalse(AppExclusions.isExcluded("com.apple.Notes", settings: settings))

        AppExclusions.toggle("com.apple.Terminal", settings: settings)
        XCTAssertFalse(AppExclusions.isExcluded("com.apple.Terminal", settings: settings), "терминал можно включить")
        AppExclusions.toggle("com.apple.Terminal", settings: settings)
        XCTAssertTrue(AppExclusions.isExcluded("com.apple.Terminal", settings: settings))

        AppExclusions.toggle("com.bitwarden.desktop", settings: settings)
        XCTAssertTrue(AppExclusions.isExcluded("com.bitwarden.desktop", settings: settings), "менеджер паролей — нельзя")
    }
}

final class SettingsPrivacyTests: XCTestCase {
    func testNewInstallSendsNothingByDefault() {
        let s = Settings(defaults: TestFiles.defaults())
        XCTAssertFalse(s.aiAutoCheck)
        XCTAssertFalse(s.aiReadWindow)
    }

    /// У тех, кто уже пользовался 1.0, поведение не меняется молча.
    func testExistingInstallKeepsPreviousBehaviour() {
        let d = TestFiles.defaults()
        d.set(true, forKey: "loginItemConfigured")
        let s = Settings(defaults: d)
        XCTAssertTrue(s.aiAutoCheck)
        XCTAssertTrue(s.aiReadWindow)
    }

    func testExplicitChoiceIsKept() {
        let d = TestFiles.defaults()
        d.set(true, forKey: "loginItemConfigured")
        d.set(false, forKey: "aiAutoCheck")
        let s = Settings(defaults: d)
        XCTAssertFalse(s.aiAutoCheck)
        // Миграция однократная: выключенное потом не включается обратно.
        s.aiReadWindow = false
        XCTAssertFalse(Settings(defaults: d).aiReadWindow)
    }

    func testHotkeyLabel() {
        let s = Settings(defaults: TestFiles.defaults())
        XCTAssertEqual(s.hotkeyLabel, "⌥⇧")
        s.hotkeyControlOption = true
        XCTAssertEqual(s.hotkeyLabel, "⌃⌥")
    }
}

final class AIConfigTests: XCTestCase {
    func testLocalHosts() {
        for h in ["localhost", "127.0.0.1", "192.168.1.20", "10.0.0.5", "172.16.3.4", "macbook.local", "::1"] {
            XCTAssertTrue(AIConfig.isLocalHost(h), h)
        }
        for h in ["api.openai.com", "8.8.8.8", "172.32.0.1", "192.169.1.1", "", "localhost.evil.com"] {
            XCTAssertFalse(AIConfig.isLocalHost(h), h)
        }
        XCTAssertFalse(AIConfig.isLocalHost(nil))
    }

    func testLanOllamaNeedsNoKey() {
        let c = AIConfig(baseURL: "http://192.168.1.20:11434/v1", model: "qwen2.5:7b", apiKey: "")
        XCTAssertTrue(c.isLocal)
        XCTAssertTrue(c.isConfigured)
    }

    func testKeyIsNeverSentOverPlainHTTPToInternet() async {
        let c = AIConfig(baseURL: "http://example.com/v1", model: "m", apiKey: "secret")
        XCTAssertTrue(c.sendsKeyInsecurely)
        XCTAssertFalse(AIConfig(baseURL: "https://example.com/v1", model: "m", apiKey: "secret").sendsKeyInsecurely)
        XCTAssertFalse(AIConfig(baseURL: "http://localhost:11434/v1", model: "m", apiKey: "secret").sendsKeyInsecurely)
        do {
            _ = try await AIClient().run(.fix, text: "привет", config: c)
            XCTFail("запрос не должен уйти")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("http://"), error.localizedDescription)
        }
    }

    func testProviderName() {
        XCTAssertEqual(AIConfig(baseURL: "https://api.openai.com/v1", model: "m", apiKey: "k").providerName, "OpenAI")
        XCTAssertEqual(AIConfig(baseURL: "https://my.host/v1", model: "m", apiKey: "k").providerName, "my.host")
    }
}

final class KeyTableTests: XCTestCase {
    func testBuiltInTableMatchesOriginalBehaviour() {
        let t = LayoutMap.builtIn
        XCTAssertTrue(t.hasAllRussianLetters)
        XCTAssertEqual(t.enKeysThatAreRuLetters, Set("`[];',.~{}:\"<>"))
        XCTAssertNil(t.ruToEn["."]); XCTAssertNil(t.ruToEn[","])
        XCTAssertEqual(t.enToRu["/"], "."); XCTAssertEqual(t.enToRu["?"], ",")
        let delimiters: [Character: Character] = ["/": ".", "?": ",", "&": "?", "^": ":", "$": ";", "@": "\"", "#": "№"]
        XCTAssertEqual(t.delimiters, delimiters)
    }

    private func table(_ ruID: String) throws -> KeyTable {
        let en = try XCTUnwrap(KeyboardLayouts.source(id: "com.apple.keylayout.US"), "нет раскладки U.S.")
        guard let ru = KeyboardLayouts.source(id: ruID) else { throw XCTSkip("нет раскладки \(ruID)") }
        return try XCTUnwrap(KeyboardLayouts.table(en: en, ru: ru))
    }

    /// Таблица, построенная по «Русская — ПК», совпадает со встроенной. Исключение — «ё»:
    /// на ISO-клавиатуре клавиша слева от «1» в английской раскладке даёт «§», а не «`».
    func testRussianPCMatchesBuiltIn() throws {
        let t = try table("com.apple.keylayout.RussianWin")
        let leftOfOne: Set<Character> = ["`", "~", "§", "±"]
        XCTAssertTrue(t.hasAllRussianLetters)
        for (ru, en) in LayoutMap.builtIn.ruToEn where ru != "ё" && ru != "Ё" {
            XCTAssertEqual(t.ruToEn[ru], en, "\(ru)")
        }
        XCTAssertTrue(["`", "§"].contains(t.ruToEn["ё"]), "\(String(describing: t.ruToEn["ё"]))")
        XCTAssertTrue(["~", "±"].contains(t.ruToEn["Ё"]), "\(String(describing: t.ruToEn["Ё"]))")
        XCTAssertEqual(t.ruToEn.keys.filter { !KeyTable.isCyrillic($0) }, [], "только русские буквы")
        XCTAssertEqual(t.enKeysThatAreRuLetters.subtracting(leftOfOne),
                       LayoutMap.builtIn.enKeysThatAreRuLetters.subtracting(leftOfOne))
        for (en, ru) in LayoutMap.builtIn.enToRu where !leftOfOne.contains(en) {
            XCTAssertEqual(t.enToRu[en], ru, "\(en)")
        }
        for (en, ru) in LayoutMap.builtIn.delimiters { XCTAssertEqual(t.delimiters[en], ru, "\(en)") }
    }

    func testKeyLeftOfOneDependsOnKeyboardType() {
        XCTAssertEqual(KeyboardLayouts.letterKeyCodes(iso: false).first, 50)
        XCTAssertEqual(KeyboardLayouts.letterKeyCodes(iso: true).first, 10)
        XCTAssertEqual(Set(KeyboardLayouts.letterKeyCodes(iso: true)), Set(KeyboardLayouts.letterKeyCodes(iso: false)))
    }

    /// Apple «Русская»: все буквы на месте, слова переводятся туда и обратно.
    func testAppleRussianLayout() throws {
        let t = try table("com.apple.keylayout.Russian")
        XCTAssertTrue(t.hasAllRussianLetters)
        let ru = "съешь же ещё этих мягких французских булок да выпей чаю"
        let en = String(ru.map { t.ruToEn[$0] ?? $0 })
        XCTAssertEqual(String(en.map { t.enToRu[$0] ?? $0 }), ru)
        XCTAssertEqual(String("ghbdtn".map { t.enToRu[$0] ?? $0 }), "привет")
    }
}

final class SpellCheckerGuardTests: XCTestCase {
    /// После медленного ответа проверщика раннее определение раскладки временно выключается.
    func testSlowSpellCheckerDisablesEarlyDetection() {
        let engine = CorrectionEngine(store: TestFiles.wordStore())
        XCTAssertFalse(engine.isSlow)
        engine.noteDuration(since: Date().addingTimeInterval(-1))
        XCTAssertTrue(engine.isSlow)
        XCTAssertNil(engine.evaluatePrefix("ghb", layout: "en"))
        engine.noteDuration(since: Date())   // быстрый ответ не сбрасывает паузу раньше времени
        XCTAssertTrue(engine.isSlow)
    }
}

final class StyleProfileTests: XCTestCase {
    func testBundledProfileIsUsedByDefault() {
        let p = StyleProfile(directory: TestFiles.tempDir(), resources: TestFiles.resources)
        XCTAssertFalse(p.descriptionText.isEmpty)
        XCTAssertTrue(p.words.contains("прога"))
    }

    /// Свой профиль в Application Support важнее встроенного.
    func testProfileInSupportDirectoryWins() throws {
        let dir = TestFiles.tempDir()
        let own = #"{"description": "Пишет коротко.", "samples": ["ок"], "words": ["кек"]}"#
        try own.write(to: dir.appendingPathComponent("style_profile.json"), atomically: true, encoding: .utf8)
        let p = StyleProfile(directory: dir, resources: TestFiles.resources)
        XCTAssertEqual(p.descriptionText, "Пишет коротко.")
        XCTAssertEqual(p.words, ["кек"])
    }
}
