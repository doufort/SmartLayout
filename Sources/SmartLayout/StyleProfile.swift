import Foundation

/// Стиль автора: описание и примеры его текстов.
/// - ~/Library/Application Support/SmartLayout/style_profile.json: ваш профиль, если он там есть
///   (так сборку можно отдать другим людям без вашего профиля внутри);
/// - Resources/style_profile.json: начальный профиль, собранный по анкете;
/// - ~/Library/Application Support/SmartLayout/style_samples.json: ваши свежие тексты,
///   которые копятся сами (отправленные сообщения, принятые правки) и постоянно обновляют стиль.
final class StyleProfile {
    private struct Profile: Codable {
        var description: String = ""
        var samples: [String] = []
        var words: [String] = []
    }

    private var base = Profile()
    private var recent: [String] = []
    private let recentURL: URL
    private let maxRecent = 40
    private var saveWork: DispatchWorkItem?

    init(directory: URL = WordStore.supportDir, resources: Bundle = .main) {
        recentURL = directory.appendingPathComponent("style_samples.json")
        let candidates = [directory.appendingPathComponent("style_profile.json"),
                          resources.url(forResource: "style_profile", withExtension: "json")]
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url), let p = try? JSONDecoder().decode(Profile.self, from: data) {
                base = p
                break
            }
        }
        if let data = try? Data(contentsOf: recentURL),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            recent = list
        }
    }

    /// Слова из профиля — добавляются к словарю, чтобы не исправлялись.
    var words: [String] { base.words }
    var descriptionText: String { base.description }

    /// Запомнить свежий текст автора (только осмысленные фразы).
    func addSample(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 15, t.count <= 600, t.split(separator: " ").count >= 3 else { return }
        if recent.last == t { return }
        recent.append(t)
        if recent.count > maxRecent { recent.removeFirst(recent.count - maxRecent) }
        scheduleSave()
    }

    func resetRecent() {
        recent.removeAll()
        scheduleSave()
    }

    var recentCount: Int { recent.count }

    /// Постоянная часть профиля для системного сообщения: описание и примеры из анкеты.
    /// Не меняется от запроса к запросу, поэтому провайдер может её кэшировать.
    func stableBlock() -> String {
        var parts: [String] = []
        if !base.description.isEmpty { parts.append("Стиль автора: \(base.description)") }
        let examples = Self.examples(base.samples, budget: 1500)
        if !examples.isEmpty {
            parts.append("Примеры того, как автор пишет на самом деле (его слова, длина фраз, тон):\n" + examples)
        }
        return parts.joined(separator: "\n")
    }

    /// Свежие тексты автора (меняются): идут в сообщение пользователя, после постоянной части.
    func recentBlock() -> String {
        let examples = Self.examples(recent.reversed(), budget: 1200)
        return examples.isEmpty ? "" : "Свежие тексты автора (самые новые сверху):\n" + examples
    }

    private static func examples<S: Sequence>(_ texts: S, budget: Int) -> String where S.Element == String {
        var out: [String] = []
        var left = budget
        for s in texts {
            guard left > 0 else { break }
            let cut = String(s.prefix(left))
            out.append("- " + cut)
            left -= cut.count
        }
        return out.joined(separator: "\n")
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let data = try? JSONEncoder().encode(self.recent) else { return }
            try? data.write(to: self.recentURL, options: .atomic)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
}
