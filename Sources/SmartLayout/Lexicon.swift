import Foundation

/// Частотные словари (`Resources/words_ru.txt`, `words_en.txt`): мгновенные ответы
/// «есть ли такое слово» и «есть ли слова с таким началом» без обращения к проверщику macOS.
///
/// Проверщик бывает медленным (до секунды), а обработчик нажатий ждать не может,
/// поэтому всё, что нужно прямо во время набора, сначала ищется здесь.
final class Lexicon {
    /// Длины начал слов, которые хранятся для раннего определения раскладки.
    static let prefixLengths = 3...5

    private var words: [String: Set<String>] = [:]
    private var prefixes: [String: Set<String>] = [:]

    init(resources: Bundle = .main) {
        for lang in ["ru", "en"] {
            guard let url = resources.url(forResource: "words_\(lang)", withExtension: "txt"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            load(lang, text.split(separator: "\n").lazy.filter { !$0.hasPrefix("#") }.map { String($0) })
        }
    }

    /// Загрузка занимает около полусекунды, поэтому при запуске она идёт в фоне;
    /// пока словарь не готов, движок работает по-старому, через проверщик.
    static func loadInBackground(resources: Bundle = .main, completion: @escaping (Lexicon) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let lexicon = Lexicon(resources: resources)
            DispatchQueue.main.async { completion(lexicon) }
        }
    }

    /// Словарь из готового списка (для тестов).
    init(_ lists: [String: [String]]) {
        for (lang, list) in lists { load(lang, list) }
    }

    private func load<S: Sequence>(_ lang: String, _ list: S) where S.Element == String {
        var w = Set<String>(), p = Set<String>()
        w.reserveCapacity(50_000)
        p.reserveCapacity(120_000)
        for word in list {
            w.insert(word)
            // Буквы — одиночные символы Unicode, поэтому режем по скалярам, без разбора графем.
            let scalars = word.unicodeScalars
            for n in Self.prefixLengths where scalars.count >= n {
                p.insert(String(String.UnicodeScalarView(scalars.prefix(n))))
            }
        }
        words[lang] = w
        prefixes[lang] = p
    }

    var isEmpty: Bool { words.values.allSatisfy(\.isEmpty) }

    func contains(_ word: String, lang: String) -> Bool {
        words[lang]?.contains(word.lowercased()) ?? false
    }

    /// Есть ли слова, начинающиеся с `prefix` (3–5 букв; для более длинных — по первым пяти).
    func hasPrefix(_ prefix: String, lang: String) -> Bool {
        let p = prefix.lowercased()
        if p.count < Self.prefixLengths.lowerBound { return true }   // слишком коротко, чтобы судить
        return prefixes[lang]?.contains(String(p.prefix(Self.prefixLengths.upperBound))) ?? false
    }
}
