import XCTest
@testable import SmartLayout

/// Тесты логики, не зависящей от macOS-окружения.
/// Запуск на Mac: `swift test` в папке проекта.
final class LayoutMapTests: XCTestCase {
    func testEnToRu() {
        XCTAssertEqual(LayoutMap.convert("ghbdtn", from: "en"), "привет")
        XCTAssertEqual(LayoutMap.convert("Ghbdtn", from: "en"), "Привет")
        XCTAssertEqual(LayoutMap.convert("k.,k.", from: "en"), "люблю")
        XCTAssertEqual(LayoutMap.convert("fdnjvfnbxtcrb", from: "en"), "автоматически")
        XCTAssertEqual(LayoutMap.convert("`krf", from: "en"), "ёлка")
    }

    func testRuToEn() {
        XCTAssertEqual(LayoutMap.convert("руддщ", from: "ru"), "hello")
        XCTAssertEqual(LayoutMap.convert("Цщкв", from: "ru"), "Word")
        XCTAssertEqual(LayoutMap.convert("вщтэе", from: "ru"), "don't")
    }

    func testRoundTrip() {
        let ru = "съешь же ещё этих мягких французских булок да выпей чаю"
        let en = LayoutMap.convert(ru, from: "ru")
        XCTAssertEqual(LayoutMap.convert(en, from: "en"), ru)
    }

    func testDelimiters() {
        XCTAssertEqual(LayoutMap.delimiterEnToRu("/"), ".")
        XCTAssertEqual(LayoutMap.delimiterEnToRu("?"), ",")
        XCTAssertEqual(LayoutMap.delimiterEnToRu("&"), "?")
        XCTAssertEqual(LayoutMap.delimiterEnToRu(" "), " ")
    }

    func testPerformance() {
        let words = Array(repeating: "ghbdtn rfr ltkf xnj ltkftim", count: 2000)
        measure { for w in words { _ = LayoutMap.convert(w, from: "en") } }
    }
}

final class TextUtilsTests: XCTestCase {
    func testEditDistance() {
        XCTAssertEqual(TextUtils.editDistance("проэкт", "проект"), 1)
        XCTAssertEqual(TextUtils.editDistance("teh", "the"), 1)          // перестановка
        XCTAssertEqual(TextUtils.editDistance("извени", "извини"), 1)
        XCTAssertEqual(TextUtils.editDistance("", "abc"), 3)
        XCTAssertEqual(TextUtils.editDistance("кот", "кот"), 0)
        XCTAssertEqual(TextUtils.editDistance("Привет", "привет"), 0)    // регистр не важен
    }

    func testMatchCase() {
        XCTAssertEqual(TextUtils.matchCase("проект", like: "Проэкт"), "Проект")
        XCTAssertEqual(TextUtils.matchCase("проект", like: "ПРОЭКТ"), "ПРОЕКТ")
        XCTAssertEqual(TextUtils.matchCase("I'm", like: "im"), "I'm")
    }

    func testEditDistancePerformance() {
        measure { for _ in 0..<3000 { _ = TextUtils.editDistance("достопримечательность", "достопремичательность") } }
    }
}

final class HumanStyleTests: XCTestCase {
    func testCleanTextPasses() {
        let o = "короче я вчера посмотрел отчет там все норм"
        let t = "Короче, я вчера посмотрел отчёт, там всё норм."
        XCTAssertEqual(HumanStyle.violations(in: t, original: o), [])
    }

    func testBannedPhrases() {
        let o = "отчет готов"
        XCTAssertFalse(HumanStyle.violations(in: "Важно отметить, что отчёт готов.", original: o).isEmpty)
        XCTAssertFalse(HumanStyle.violations(in: "Отчёт играет ключевую роль.", original: o).isEmpty)
        XCTAssertFalse(HumanStyle.violations(in: "Это не просто отчёт, это результат.", original: o).isEmpty)
        // Если оборот был у автора — это не нарушение.
        XCTAssertEqual(HumanStyle.violations(in: "Важно отметить: отчёт готов.", original: "важно отметить отчет готов"), [])
    }

    func testMarkdownEmojiDashes() {
        let o = "все готово можно запускать"
        XCTAssertFalse(HumanStyle.violations(in: "**Всё готово**, можно запускать.", original: o).isEmpty)
        XCTAssertFalse(HumanStyle.violations(in: "Всё готово, можно запускать 🚀", original: o).isEmpty)
        XCTAssertFalse(HumanStyle.violations(in: "Всё — готово — можно — запускать.", original: o).isEmpty)
        XCTAssertFalse(HumanStyle.violations(in: "- Всё готово\n- Можно запускать", original: o).isEmpty)
    }

    func testFromTo() {
        XCTAssertFalse(HumanStyle.violations(in: "Подходит всем, от новичков до профи.", original: "подходит всем").isEmpty)
    }

    func testSlangKept() {
        let slang: Set<String> = ["пж", "скрин", "баг"]
        let o = "скинь пж скрин а то не понял где баг"
        let bad = "Скинь, пожалуйста, скриншот, а то не понял, где ошибка."
        let good = "Скинь, пж, скрин, а то не понял, где баг."
        XCTAssertFalse(HumanStyle.violations(in: bad, original: o, slang: slang).isEmpty)
        XCTAssertEqual(HumanStyle.violations(in: good, original: o, slang: slang), [])
    }

    func testTooLong() {
        let o = "ок понял"
        let t = "Хорошо, я понял тебя и полностью согласен со всем, что ты сказал, давай так и сделаем завтра утром."
        XCTAssertFalse(HumanStyle.violations(in: t, original: o).isEmpty)
    }

    func testPerformanceOnLongText() {
        let o = String(repeating: "я тут подумал что надо встретится и обсудить проект ", count: 60)
        let t = String(repeating: "Я тут подумал, что надо встретиться и обсудить проект. ", count: 60)
        measure { for _ in 0..<200 { _ = HumanStyle.violations(in: t, original: o, slang: ["пж"]) } }
    }
}

final class LearningTests: XCTestCase {
    func testWordChanges() {
        let pairs = LearningStore.wordChanges(from: "проэкт почти готов", to: "Проект почти готов.")
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.0, "проэкт")
        XCTAssertEqual(pairs.first?.1, "Проект")
        // Разное число слов — пары не определяем.
        XCTAssertTrue(LearningStore.wordChanges(from: "я незнаю", to: "Я не знаю").isEmpty)
        // Только знаки и регистр — не изменение слова.
        XCTAssertTrue(LearningStore.wordChanges(from: "привет как дела", to: "Привет, как дела?").isEmpty)
    }

    func testLearnUnknownAfterThreeTimes() {
        let l = LearningStore(url: TestFiles.tempFile("learning.json"))
        l.reset()
        let w = "кринжатинабот"
        l.noteUnknown(w); l.noteUnknown(w)
        XCTAssertFalse(l.learnedWords.contains(w))
        l.noteUnknown(w)
        XCTAssertTrue(l.typedWords.contains(w))
        XCTAssertFalse(l.learnedWords.contains(w), "набранное 3 раза не должно считаться явно подтверждённым")
    }

    func testAcceptAndReject() {
        let l = LearningStore(url: TestFiles.tempFile("learning.json"))
        l.reset()
        l.noteAccepted([("сдесь", "здесь")])
        XCTAssertNil(l.learnedTypos["сдесь"])
        l.noteAccepted([("сдесь", "здесь")])
        XCTAssertEqual(l.learnedTypos["сдесь"], "здесь")
        l.noteRejected([("чет", "чёт")]); l.noteRejected([("чет", "чёт")])
        XCTAssertTrue(l.protectedWords.contains("чет"))
    }

    func testStressManyUnknownWords() {
        let l = LearningStore(url: TestFiles.tempFile("learning.json"))
        l.reset()
        measure { for i in 0..<20_000 { l.noteUnknown("слово\(i % 3000)") } }
        XCTAssertGreaterThan(l.typedWords.count, 0)
    }

    /// Переполнение: редкие одноразовые слова вытесняются, а частые продолжают учиться.
    func testOverflowKeepsFrequentWords() {
        let l = LearningStore(url: TestFiles.tempFile("learning.json"))
        l.reset()
        for i in 0..<12_000 {
            l.noteUnknown("одноразовое\(i)")
            if i % 1000 == 0 { l.noteUnknown("частоеслово") }
        }
        XCTAssertTrue(l.typedWords.contains("частоеслово"))
    }
}
