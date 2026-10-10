import Foundation
@testable import SmartLayout

/// Временные файлы и ресурсы для тестов: тесты не должны трогать
/// ~/Library/Application Support/SmartLayout и настройки настоящего приложения.
enum TestFiles {
    static func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmartLayoutTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func tempFile(_ name: String) -> URL { tempDir().appendingPathComponent(name) }

    /// Папка Resources репозитория как Bundle (словари slang_*/typos_*).
    static var resources: Bundle {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: root.appendingPathComponent("Resources"))!
    }

    static func defaults() -> UserDefaults {
        let name = "SmartLayoutTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    static func wordStore() -> WordStore {
        WordStore(directory: tempDir(), defaults: defaults(), resources: resources)
    }

    /// Частотный словарь из Resources (грузится один раз на все тесты).
    static let lexicon = Lexicon(resources: resources)

    static func engine() -> CorrectionEngine { CorrectionEngine(store: wordStore(), lexicon: lexicon) }
}
