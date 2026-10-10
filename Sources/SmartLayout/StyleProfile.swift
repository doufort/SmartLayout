import Foundation

/// Стиль автора: описание и примеры его текстов.
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
    private let recentURL = WordStore.supportDir.appendingPathComponent("style_samples.json")
    private let maxRecent = 40
    private var saveWork: DispatchWorkItem?

    init() {
        if let url = Bundle.main.url(forResource: "style_profile", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let p = try? JSONDecoder().decode(Profile.self, from: data) {
            base = p
        }
        if let data = try? Data(contentsOf: recentURL),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            recent = list
        }
    }

    /// Слова из профиля — добавляются к словарю, чтобы не исправлялись.
    var words: [String] { base.words }

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

    /// Блок для инструкции модели (до ~2500 символов).
    func promptBlock() -> String {
        var parts: [String] = []
        if !base.description.isEmpty { parts.append("Стиль автора: \(base.description)") }
        var examples: [String] = []
        var budget = 2200
        // Сначала свежие тексты, потом примеры из анкеты.
        for s in recent.reversed() + base.samples {
            guard budget > 0 else { break }
            let cut = String(s.prefix(min(s.count, budget)))
            examples.append("- " + cut)
            budget -= cut.count
        }
        if !examples.isEmpty {
            parts.append("Примеры того, как автор пишет на самом деле (его слова, длина фраз, тон):\n" +
                         examples.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n")
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
