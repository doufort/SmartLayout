import AppKit

/// Приложения, в которых SmartLayout не трогает набор и ничего не отправляет ИИ.
///
/// По умолчанию это терминалы, редакторы кода и менеджеры паролей: в терминале
/// `ls`, `git`, ключи и пути легко принять за слово в другой раскладке, а набранное там
/// (токены, пароли) нельзя отправлять облачной модели. Терминалы и редакторы можно включить
/// обратно из меню, менеджеры паролей — нельзя.
enum AppExclusions {
    /// Всегда исключены, вернуть нельзя.
    static let locked: [String] = [
        "com.1password.", "com.agilebits.onepassword", "com.bitwarden.desktop",
        "com.lastpass.", "com.dashlane.", "org.keepassxc.keepassxc", "com.apple.Passwords",
        "com.apple.keychainaccess"
    ]

    /// Исключены по умолчанию, но их можно включить в меню.
    /// Значение с точкой на конце — префикс (все приложения JetBrains и т.п.).
    static let defaults: [String] = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
        "com.github.wez.wezterm", "io.alacritty", "com.mitchellh.ghostty", "co.zeit.hyper",
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", // Cursor
        "com.apple.dt.Xcode", "com.jetbrains.", "com.google.android.studio", "com.sublimetext.",
        "com.panic.Nova", "dev.zed.Zed"
    ]

    static func matches(_ bundleID: String, _ pattern: String) -> Bool {
        pattern.hasSuffix(".") ? bundleID.hasPrefix(pattern) : bundleID == pattern
    }

    static func isLocked(_ bundleID: String) -> Bool { locked.contains { matches(bundleID, $0) } }
    static func isDefault(_ bundleID: String) -> Bool { defaults.contains { matches(bundleID, $0) } }

    /// Чистое решение без обращения к настройкам (покрыто тестами).
    static func isExcluded(_ bundleID: String?, userExcluded: Set<String>, userAllowed: Set<String>) -> Bool {
        guard let id = bundleID, !id.isEmpty else { return false }
        if isLocked(id) { return true }
        if userExcluded.contains(id) { return true }
        if userAllowed.contains(id) { return false }
        return isDefault(id)
    }

    static func isExcluded(_ bundleID: String?, settings: Settings = .shared) -> Bool {
        isExcluded(bundleID, userExcluded: settings.excludedApps, userAllowed: settings.allowedApps)
    }

    /// Переключить приложение: исключённое включается, включённое исключается.
    static func toggle(_ bundleID: String, settings: Settings = .shared) {
        guard !isLocked(bundleID) else { return }
        if isExcluded(bundleID, settings: settings) {
            settings.excludedApps.remove(bundleID)
            if isDefault(bundleID) { settings.allowedApps.insert(bundleID) }
        } else {
            settings.allowedApps.remove(bundleID)
            if !isDefault(bundleID) { settings.excludedApps.insert(bundleID) }
        }
        refresh()
    }

    // MARK: Текущее приложение

    /// Последнее активное приложение, кроме самого SmartLayout (его меню не делает себя активным,
    /// но окно настроек — делает).
    private(set) static var frontmost: NSRunningApplication?
    /// Кэш решения для активного приложения: проверяется на каждое нажатие клавиши.
    private(set) static var frontmostExcluded = false
    private static var observer: NSObjectProtocol?

    static func startTracking(onChange: @escaping () -> Void) {
        update(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            AppExclusions.update(app)
            onChange()
        }
    }

    static func refresh() { frontmostExcluded = isExcluded(frontmost?.bundleIdentifier) }

    private static func update(_ app: NSRunningApplication?) {
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        frontmost = app
        refresh()
    }
}
