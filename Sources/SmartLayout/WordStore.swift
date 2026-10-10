import Foundation

/// Дополнительные слова (сленг, пользовательский словарь) и исключения.
final class WordStore {
    private(set) var words = Set<String>()
    /// Частые опечатки: неправильно -> правильно.
    private(set) var typos = [String: String]()
    private(set) var exceptions: Set<String>
    let learning: LearningStore
    /// Ваш словарь: по умолчанию ~/Library/Application Support/SmartLayout/user_words.txt.
    let userWordsURL: URL
    private let defaults: UserDefaults
    private let resources: Bundle
    private let exceptionsKey = "exceptions"

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("SmartLayout", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `directory`, `defaults` и `resources` подменяются в тестах, чтобы не трогать ваши настоящие данные.
    init(directory: URL = WordStore.supportDir, defaults: UserDefaults = .standard, resources: Bundle = .main) {
        self.defaults = defaults
        self.resources = resources
        userWordsURL = directory.appendingPathComponent("user_words.txt")
        learning = LearningStore(url: directory.appendingPathComponent("learning.json"))
        exceptions = Set(defaults.stringArray(forKey: exceptionsKey) ?? [])
        reload()
    }

    func reload() {
        var set = Set<String>()
        for name in ["slang_ru", "slang_en"] {
            if let url = resources.url(forResource: name, withExtension: "txt") {
                set.formUnion(Self.load(url))
            }
        }
        let userURL = userWordsURL
        if !FileManager.default.fileExists(atPath: userURL.path) {
            let header = "# Свои слова, по одному на строку. Они не будут исправляться.\n"
            try? header.write(to: userURL, atomically: true, encoding: .utf8)
        }
        set.formUnion(Self.load(userURL))
        words = set

        var map = [String: String]()
        for name in ["typos_ru", "typos_en"] {
            guard let url = resources.url(forResource: name, withExtension: "txt") else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty { map[parts[0].lowercased()] = parts[1] }
            }
        }
        typos = map
    }

    private static func load(_ url: URL) -> Set<String> {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") })
    }

    func contains(_ word: String) -> Bool {
        let w = word.lowercased()
        return words.contains(w) || learning.learnedWords.contains(w) || learning.typedWords.contains(w)
            || learning.protectedWords.contains(w)
    }

    /// Известная опечатка: из файла typos или выученная на ваших правках.
    func typoFix(_ word: String) -> String? {
        let w = word.lowercased()
        if learning.learnedWords.contains(w) || learning.protectedWords.contains(w) { return nil }
        return learning.learnedTypos[w] ?? typos[w]
    }

    /// Слова для подсказки ИИ: ваш словарь и то, что вы явно оставили (до 150 штук).
    /// Слова, которые просто часто набирались (`typedWords`), сюда не входят:
    /// среди них бывают ваши привычные опечатки, и ИИ должен иметь право их поправить.
    var glossaryForAI: [String] {
        var list = Array(learning.protectedWords) + Array(learning.learnedWords)
        if let text = try? String(contentsOf: userWordsURL, encoding: .utf8) {
            list += text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        return Array(Set(list)).sorted().prefix(150).map { $0 }
    }

    func isException(_ token: String) -> Bool { exceptions.contains(token.lowercased()) }

    func addException(_ token: String) {
        exceptions.insert(token.lowercased())
        learning.learnWord(token.trimmingCharacters(in: .punctuationCharacters))
        defaults.set(Array(exceptions), forKey: exceptionsKey)
    }

    func clearExceptions() {
        exceptions.removeAll()
        defaults.removeObject(forKey: exceptionsKey)
    }
}
