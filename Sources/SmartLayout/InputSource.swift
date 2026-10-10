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

    /// Раскладка указанного языка, на которую переключаемся: текущая, если она этого языка,
    /// иначе первая включённая.
    static func source(language: String) -> TISInputSource? {
        if let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           languages(of: current).first?.hasPrefix(language) == true {
            return current
        }
        let filter: [String: Any] = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable as String: true
        ]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?
            .takeRetainedValue() as? [TISInputSource] else { return nil }
        return list.first { languages(of: $0).first?.hasPrefix(language) == true }
    }

    /// Переключает на раскладку указанного языка.
    @discardableResult
    static func select(language: String) -> Bool {
        guard let src = source(language: language) else { return false }
        return TISSelectInputSource(src) == noErr
    }
}
