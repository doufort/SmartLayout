import AppKit
import XCTest
@testable import SmartLayout

/// Ускорение: частотный словарь и проверка слов без ожидания проверщика macOS.
final class LexiconTests: XCTestCase {
    func testSmallLexicon() {
        let l = Lexicon(["ru": ["привет", "пример"], "en": ["hello"]])
        XCTAssertTrue(l.contains("Привет", lang: "ru"))
        XCTAssertFalse(l.contains("привет", lang: "en"))
        XCTAssertTrue(l.hasPrefix("при", lang: "ru"))
        XCTAssertTrue(l.hasPrefix("прим", lang: "ru"))
        XCTAssertTrue(l.hasPrefix("приветик", lang: "ru"), "длинное начало проверяется по первым пяти буквам")
        XCTAssertFalse(l.hasPrefix("пру", lang: "ru"))
        XCTAssertTrue(l.hasPrefix("пр", lang: "ru"), "по двум буквам не судим")
        XCTAssertFalse(Lexicon([:]).hasPrefix("abc", lang: "en"))
        XCTAssertTrue(Lexicon([:]).isEmpty)
    }

    func testBundledWordLists() {
        let l = TestFiles.lexicon
        XCTAssertFalse(l.isEmpty)
        for w in ["привет", "спасибо", "компьютер", "сегодня"] { XCTAssertTrue(l.contains(w, lang: "ru"), w) }
        for w in ["hello", "thanks", "computer", "today"] { XCTAssertTrue(l.contains(w, lang: "en"), w) }
        XCTAssertFalse(l.contains("ghbdtn", lang: "en"))
        XCTAssertFalse(l.contains("руддщ", lang: "ru"))
        XCTAssertFalse(l.hasPrefix("ьфшд", lang: "ru"))
        XCTAssertFalse(l.hasPrefix("ghbd", lang: "en"))
        XCTAssertTrue(l.hasPrefix("прив", lang: "ru"))
    }

    /// Загрузка идёт в фоне, но время всё равно следим (около полусекунды на 80 тыс. слов).
    func testLoadingTime() {
        measure { _ = Lexicon(resources: TestFiles.resources) }
    }

    func testBackgroundLoadingDeliversOnMain() {
        let done = expectation(description: "lexicon")
        Lexicon.loadInBackground(resources: TestFiles.resources) { lexicon in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(lexicon.contains("привет", lang: "ru"))
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }

    /// Пока словарь грузится, движок работает через проверщик; после `use` — через словарь.
    func testEngineStartsWithoutLexiconAndSwitches() {
        let engine = CorrectionEngine(store: TestFiles.wordStore())
        XCTAssertTrue(engine.lexicon.isEmpty)
        engine.use(TestFiles.lexicon)
        guard case .keep = engine.evaluateCached(token: "hello", layout: "en") else { return XCTFail("hello") }
    }
}

final class CachedEvaluationTests: XCTestCase {
    private var engine: CorrectionEngine!

    override func setUpWithError() throws {
        let langs = NSSpellChecker.shared.availableLanguages
        try XCTSkipUnless(langs.contains { $0.hasPrefix("ru") } && langs.contains { $0.hasPrefix("en") },
                          "нужны русский и английский словари проверки орфографии macOS")
        engine = TestFiles.engine()
    }

    /// Частые слова решаются мгновенно, без проверщика.
    func testCommonWordsNeedNoSpellChecker() {
        guard case .keep = engine.evaluateCached(token: "hello", layout: "en") else { return XCTFail("hello") }
        guard case .keep = engine.evaluateCached(token: "привет,", layout: "ru") else { return XCTFail("привет") }
        guard case .fix(let f) = engine.evaluateCached(token: "вообщем", layout: "ru") else { return XCTFail("опечатка") }
        XCTAssertEqual(f.replacement, "в общем")
    }

    /// Неизвестное слово откладывается, проверяется в фоне и потом исправляется.
    func testUnknownWordIsCheckedInBackground() {
        guard case .pending(let keys) = engine.evaluateCached(token: "ghbdtn", layout: "en") else {
            return XCTFail("ghbdtn нет в частотном словаре — нужен ответ проверщика")
        }
        XCTAssertEqual(keys, [WordKey(word: "ghbdtn", lang: "en")], "«привет» уже известно из частотного словаря")
        let done = expectation(description: "prefetch")
        engine.prefetch(keys) { done.fulfill() }
        wait(for: [done], timeout: 10)
        guard case .fix(let fix) = engine.evaluateCached(token: "ghbdtn", layout: "en") else { return XCTFail("после проверки") }
        XCTAssertEqual(fix.replacement, "привет")
        XCTAssertEqual(fix.switchTo, "ru")
    }

    /// Фоновая проверка даёт тот же ответ, что и синхронная.
    func testBackgroundCheckMatchesSyncCheck() {
        let words = [WordKey(word: "ghbdtn", lang: "en"), WordKey(word: "inert", lang: "en"),
                     WordKey(word: "игуана", lang: "ru"), WordKey(word: "фывапр", lang: "ru")]
        let sync = TestFiles.engine()
        let done = expectation(description: "prefetch")
        engine.prefetch(Set(words)) { done.fulfill() }
        wait(for: [done], timeout: 10)
        for k in words {
            XCTAssertEqual(engine.validity(k.word, lang: k.lang, cachedOnly: true), sync.isValid(k.word, lang: k.lang), k.word)
        }
    }

    func testEarlyDetectionStartsAtFourLetters() {
        XCTAssertNil(engine.evaluatePrefix("ghb", layout: "en"))
        XCTAssertEqual(engine.evaluatePrefix("ghbd", layout: "en")?.replacement, "прив")
        XCTAssertNil(engine.evaluatePrefix("hell", layout: "en"))
    }

    /// То, что делается на каждом нажатии, должно укладываться в микросекунды.
    func testCachedEvaluationSpeed() {
        let tokens = ["hello", "привет", "ghbdtn", "world", "сегодня", "rjvgm.nth", "google.com", "кринж"]
        measure {
            for _ in 0..<500 { for t in tokens { _ = engine.evaluateCached(token: t, layout: t.first!.isASCII ? "en" : "ru") } }
        }
    }
}
