import Carbon

/// Работа с раскладками клавиатуры через Text Input Sources.
enum InputSource {
    static func languages(of src: TISInputSource) -> [String] {
        guard let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages) else { return [] }
        let arr = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String]
        return arr ?? []
    }

    /// Код языка текущей раскладки: "en", "ru" и т.п.
    static func currentLanguage() -> String? {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return languages(of: src).first.map { String($0.prefix(2)) }
    }

    /// Переключает на первую доступную раскладку указанного языка.
    @discardableResult
    static func select(language: String) -> Bool {
        let filter: [String: Any] = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable as String: true
        ]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?
            .takeRetainedValue() as? [TISInputSource] else { return false }
        for src in list where languages(of: src).first?.hasPrefix(language) == true {
            return TISSelectInputSource(src) == noErr
        }
        return false
    }
}
