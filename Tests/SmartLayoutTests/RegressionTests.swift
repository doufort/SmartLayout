import AppKit
import XCTest
@testable import SmartLayout

/// Тесты на ошибки, найденные при аудите (docs/AUDIT.md).
final class LearningStoreRegressionTests: XCTestCase {
    /// learning.json от прошлой версии без нового поля не должен обнулять выученное.
    func testOldFileWithoutNewFieldsStillLoads() throws {
        let url = TestFiles.tempFile("learning.json")
        let old = #"{"unknownCounts":{},"learnedWords":["кек"],"acceptedPairs":{},"learnedTypos":{"сдесь":"здесь"},"rejectedCounts":{},"protectedWords":[]}"#
        try old.write(to: url, atomically: true, encoding: .utf8)
        let l = LearningStore(url: url)
        XCTAssertTrue(l.learnedWords.contains("кек"))
        XCTAssertEqual(l.learnedTypos["сдесь"], "здесь")
    }

    func testSavedDataRoundTrips() {
        let url = TestFiles.tempFile("learning.json")
        let a = LearningStore(url: url)
        a.learnWord("Збс")
        a.noteAccepted([("сдесь", "здесь")]); a.noteAccepted([("сдесь", "здесь")])
        a.saveNow()
        let b = LearningStore(url: url)
        XCTAssertTrue(b.learnedWords.contains("збс"))
        XCTAssertEqual(b.learnedTypos["сдесь"], "здесь")
    }

    /// Привычная опечатка, набранная 3 раза, не должна уходить ИИ как «слово автора, не исправлять».
    func testTypedWordsAreNotSentToAIAsProtected() {
        let store = TestFiles.wordStore()
        for _ in 0..<LearningStore.learnAfterTyping { store.learning.noteUnknown("делаеш") }
        XCTAssertTrue(store.contains("делаеш"), "движок больше не трогает слово")
        XCTAssertFalse(store.glossaryForAI.contains("делаеш"), "но ИИ может его поправить")
        store.addException("кринжатина")
        XCTAssertTrue(store.glossaryForAI.contains("кринжатина"), "явно оставленное слово ИИ знает")
    }

    /// Если ИИ-правку приняли дважды, слово перестаёт быть «своим».
    func testAcceptedFixOverridesTypedWord() {
        let l = LearningStore(url: TestFiles.tempFile("learning.json"))
        for _ in 0..<LearningStore.learnAfterTyping { l.noteUnknown("делаеш") }
        l.noteAccepted([("делаеш", "делаешь")]); l.noteAccepted([("делаеш", "делаешь")])
        XCTAssertFalse(l.typedWords.contains("делаеш"))
        XCTAssertEqual(l.learnedTypos["делаеш"], "делаешь")
    }
}

final class WordStoreTests: XCTestCase {
    func testLoadsBundledDictionaries() {
        let store = TestFiles.wordStore()
        XCTAssertTrue(store.contains("кринж"))
        XCTAssertTrue(store.contains("LOL"))
        XCTAssertEqual(store.typoFix("Вообщем"), "в общем")
        XCTAssertEqual(store.typoFix("teh"), "the")
        XCTAssertNil(store.typoFix("привет"))
    }

    func testExceptionsUseInjectedDefaults() {
        let d = TestFiles.defaults()
        let store = WordStore(directory: TestFiles.tempDir(), defaults: d, resources: TestFiles.resources)
        store.addException("Ghbdtn")
        XCTAssertTrue(store.isException("ghbdtn"))
        XCTAssertEqual(d.stringArray(forKey: "exceptions"), ["ghbdtn"])
        store.clearExceptions()
        XCTAssertFalse(store.isException("ghbdtn"))
    }

    func testCreatesUserWordsFileInGivenDirectory() {
        let dir = TestFiles.tempDir()
        let store = WordStore(directory: dir, defaults: TestFiles.defaults(), resources: TestFiles.resources)
        XCTAssertEqual(store.userWordsURL.deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.userWordsURL.path))
    }
}

final class AIParsingTests: XCTestCase {
    func testValidReview() throws {
        let r = try XCTUnwrap(AIClient.parseReview(#"{"fixed": "Привет, как дела?", "alternative": "Привет! Как ты?", "note": "", "next": "Давно не виделись"}"#))
        XCTAssertEqual(r.text, "Привет, как дела?")
        XCTAssertEqual(r.alternative, "Привет! Как ты?")
        XCTAssertNil(r.note)
        XCTAssertEqual(r.next, "Давно не виделись")
    }

    func testReviewInCodeFence() throws {
        let r = try XCTUnwrap(AIClient.parseReview("```json\n{\"fixed\": \"Ок.\"}\n```"))
        XCTAssertEqual(r.text, "Ок.")
    }

    /// Обрезанный ответ раньше показывался как «исправленный текст» и вставлялся в поле.
    func testTruncatedReviewIsRejected() {
        XCTAssertNil(AIClient.parseReview(#"{"fixed": "Привет, как дела?", "alternative": "Привет! Как"#))
        XCTAssertNil(AIClient.parseReview(#"Вот ответ: "fixed": "Привет""#))
        XCTAssertNil(AIClient.parseImprove(#"{"text": "Улучшенный"#))
    }

    func testPlainTextAnswerIsStillAccepted() throws {
        XCTAssertEqual(try XCTUnwrap(AIClient.parseReview("Привет, как дела?")).text, "Привет, как дела?")
        XCTAssertEqual(try XCTUnwrap(AIClient.parseImprove("<<<Привет>>>")).text, "Привет")
    }
}

final class ClipboardTests: XCTestCase {
    /// Раньше сохранялся только текст: скопированная картинка пропадала после исправления.
    func testSnapshotKeepsAllTypes() {
        let pb = NSPasteboard(name: NSPasteboard.Name("SmartLayoutTests-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setString("подпись", forType: .string)
        pb.clearContents()
        pb.writeObjects([item])

        let saved = Clipboard.snapshot(pb)
        pb.clearContents()
        pb.setString("временный текст", forType: .string)
        Clipboard.restore(saved, to: pb)

        XCTAssertEqual(pb.data(forType: .png), png)
        XCTAssertEqual(pb.string(forType: .string), "подпись")
    }

    func testRestoreEmptySnapshotClears() {
        let pb = NSPasteboard(name: NSPasteboard.Name("SmartLayoutTests-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let saved = Clipboard.snapshot(pb)
        pb.setString("x", forType: .string)
        Clipboard.restore(saved, to: pb)
        XCTAssertNil(pb.string(forType: .string))
    }
}

final class SuggestionPanelTests: XCTestCase {
    /// Продолжение набора и таймаут закрывают подсказку, но не считаются отказом от правки:
    /// иначе после двух таких закрытий ИИ навсегда переставал исправлять слово.
    func testOnlyExplicitCancelCountsAsRejection() {
        let panel = SuggestionPanel()
        var rejected = 0
        panel.show(title: "t", suggestion: "s", note: nil, near: NSRect(x: 100, y: 100, width: 1, height: 1),
                   onReject: { rejected += 1 }) {}
        panel.hide()
        XCTAssertEqual(rejected, 0)

        panel.show(title: "t", suggestion: "s", note: nil, near: NSRect(x: 100, y: 100, width: 1, height: 1),
                   onReject: { rejected += 1 }) {}
        panel.hide(rejected: true)
        XCTAssertEqual(rejected, 1)
    }
}

final class CorrectionEngineTests: XCTestCase {
    private var engine: CorrectionEngine!

    override func setUpWithError() throws {
        let langs = NSSpellChecker.shared.availableLanguages
        try XCTSkipUnless(langs.contains { $0.hasPrefix("ru") } && langs.contains { $0.hasPrefix("en") },
                          "нужны русский и английский словари проверки орфографии macOS")
        engine = CorrectionEngine(store: TestFiles.wordStore())
    }

    func testWrongLayoutIsConverted() {
        let fix = engine.evaluate(token: "ghbdtn", layout: "en")
        XCTAssertEqual(fix?.replacement, "привет")
        XCTAssertEqual(fix?.switchTo, "ru")
        XCTAssertEqual(engine.evaluate(token: "руддщ", layout: "ru")?.replacement, "hello")
    }

    func testRussianWordsWithPunctuationKeys() {
        // б, ж, ю, э, х, ъ стоят на клавишах , ; . ' [ ]
        XCTAssertEqual(engine.evaluate(token: "k.,k.", layout: "en")?.replacement, "люблю")
        XCTAssertEqual(engine.evaluate(token: "rjvgm.nth", layout: "en")?.replacement, "компьютер")
    }

    /// Раньше любое незнакомое слово с точкой внутри «переводилось» в русскую раскладку.
    func testDomainsAndAbbreviationsAreLeftAlone() {
        for token in ["google.com", "mail.ru", "github.io", "e.g.", "i.e.", "readme.md", "v1.2"] {
            XCTAssertNil(engine.evaluate(token: token, layout: "en"), token)
        }
    }

    func testValidWordsAreLeftAlone() {
        XCTAssertNil(engine.evaluate(token: "hello", layout: "en"))
        XCTAssertNil(engine.evaluate(token: "привет", layout: "ru"))
        XCTAssertNil(engine.evaluate(token: "кринж", layout: "ru"), "сленг не трогаем")
    }

    func testCommonTypos() {
        XCTAssertEqual(engine.evaluate(token: "вообщем", layout: "ru")?.replacement, "в общем")
        XCTAssertEqual(engine.evaluate(token: "Извени,", layout: "ru")?.replacement, "Извини,")
        XCTAssertEqual(engine.evaluate(token: "teh", layout: "en")?.replacement, "the")
    }
}
