import Foundation

/// Вспомогательные функции для текста (без AppKit, покрыты тестами).
enum TextUtils {
    /// Расстояние Дамерау–Левенштейна (вставка, удаление, замена, перестановка соседних букв).
    static func editDistance(_ a: String, _ b: String) -> Int {
        let s = Array(a.lowercased()), t = Array(b.lowercased())
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var d = Array(repeating: Array(repeating: 0, count: t.count + 1), count: s.count + 1)
        for i in 0...s.count { d[i][0] = i }
        for j in 0...t.count { d[0][j] = j }
        for i in 1...s.count {
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, s[i - 1] == t[j - 2], s[i - 2] == t[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[s.count][t.count]
    }

    static func matchCase(_ fixed: String, like original: String) -> String {
        guard let f = original.first else { return fixed }
        if original.count > 1 && original == original.uppercased() { return fixed.uppercased() }
        if f.isUppercase { return fixed.prefix(1).uppercased() + fixed.dropFirst() }
        return fixed
    }
}
