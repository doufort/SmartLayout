import Foundation

/// Самообучение на ваших действиях. Всё хранится локально:
/// ~/Library/Application Support/SmartLayout/learning.json
///
/// - слово, которое вы набрали 3 раза и не исправили, становится «своим» и больше не исправляется;
/// - если вы 2 раза приняли одну и ту же правку от ИИ, она начинает применяться сразу, без ИИ;
/// - если вы 2 раза отклонили правку слова, ИИ получает его в списке «не трогать»;
/// - выученные слова передаются ИИ как ваш словарь, чтобы он понимал ваш сленг.
final class LearningStore {
    private struct Data: Codable {
        var unknownCounts: [String: Int] = [:]
        var learnedWords: Set<String> = []
        var acceptedPairs: [String: Int] = [:]   // "было→стало": сколько раз принято
        var learnedTypos: [String: String] = [:]
        var rejectedCounts: [String: Int] = [:]
        var protectedWords: Set<String> = []
    }

    private var data = Data()
    private let url = WordStore.supportDir.appendingPathComponent("learning.json")
    private var saveWork: DispatchWorkItem?

    static let learnAfterTyping = 3
    static let learnAfterAccepts = 2
    static let protectAfterRejects = 2

    init() {
        if let raw = try? Foundation.Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Data.self, from: raw) {
            data = decoded
        }
    }

    var learnedWords: Set<String> { data.learnedWords }
    var learnedTypos: [String: String] { data.learnedTypos }
    var protectedWords: Set<String> { data.protectedWords }
    var learnedCount: Int { data.learnedWords.count + data.learnedTypos.count + data.protectedWords.count }

    /// Слово не нашлось в словарях и не было исправлено.
    func noteUnknown(_ word: String) {
        let w = word.lowercased()
        guard w.count >= 2, !data.learnedWords.contains(w) else { return }
        let n = (data.unknownCounts[w] ?? 0) + 1
        if n >= Self.learnAfterTyping {
            data.unknownCounts[w] = nil
            data.learnedWords.insert(w)
        } else {
            data.unknownCounts[w] = n
        }
        // Не даём списку расти бесконечно: выкидываем слова, встреченные лишь один раз.
        if data.unknownCounts.count > 5000 {
            data.unknownCounts = data.unknownCounts.filter { $0.value > 1 }
            if data.unknownCounts.count > 5000 { data.unknownCounts.removeAll() }
        }
        scheduleSave()
    }

    /// Пользователь явно оставил слово как есть (отменил исправление).
    func learnWord(_ word: String) {
        data.learnedWords.insert(word.lowercased())
        data.learnedTypos[word.lowercased()] = nil
        scheduleSave()
    }

    func noteAccepted(_ pairs: [(String, String)]) {
        for (from, to) in pairs {
            let f = from.lowercased(), t = to.lowercased()
            let key = f + "→" + t
            let n = (data.acceptedPairs[key] ?? 0) + 1
            data.acceptedPairs[key] = n
            if n >= Self.learnAfterAccepts && !data.learnedWords.contains(f) { data.learnedTypos[f] = to }
            data.rejectedCounts[f] = nil
            data.protectedWords.remove(f)
        }
        scheduleSave()
    }

    func noteRejected(_ pairs: [(String, String)]) {
        for (from, _) in pairs {
            let f = from.lowercased()
            let n = (data.rejectedCounts[f] ?? 0) + 1
            data.rejectedCounts[f] = n
            if n >= Self.protectAfterRejects {
                data.protectedWords.insert(f)
                data.learnedTypos[f] = nil
            }
        }
        scheduleSave()
    }

    func reset() {
        data = Data()
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let raw = try? JSONEncoder().encode(self.data) else { return }
            try? raw.write(to: self.url, options: .atomic)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Пары изменённых слов между исходным и исправленным текстом
    /// (только если количество слов совпадает и изменились буквы, а не только знаки).
    static func wordChanges(from original: String, to fixed: String) -> [(String, String)] {
        let strip: (Substring) -> String = { $0.trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }
        let a = original.split(whereSeparator: \.isWhitespace).map(strip)
        let b = fixed.split(whereSeparator: \.isWhitespace).map(strip)
        guard a.count == b.count else { return [] }
        return zip(a, b).filter { !$0.0.isEmpty && !$0.1.isEmpty && $0.0.lowercased() != $0.1.lowercased() }
    }
}
