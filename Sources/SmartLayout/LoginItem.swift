import ServiceManagement

/// Автозапуск при входе в систему и перезапуск после сбоя.
/// Основной способ — фоновый агент launchd (Contents/Library/LaunchAgents):
/// он стартует при входе и поднимает приложение снова, если оно упало.
/// Если агент зарегистрировать не удалось, используется обычный объект входа.
enum LoginItem {
    static let agentPlist = "com.dmitry.smartlayout.agent.plist"
    private static var agent: SMAppService { SMAppService.agent(plistName: agentPlist) }

    static var isEnabled: Bool {
        agent.status == .enabled || SMAppService.mainApp.status == .enabled
    }

    /// macOS ждёт, пока пользователь разрешит запуск в «Объектах входа».
    static var needsApproval: Bool {
        agent.status == .requiresApproval || SMAppService.mainApp.status == .requiresApproval
    }

    static func enable() {
        do {
            try agent.register()
        } catch {
            NSLog("SmartLayout: агент не зарегистрирован (\(error)), пробую объект входа")
            try? SMAppService.mainApp.register()
        }
    }

    static func disable() {
        try? agent.unregister()
        try? SMAppService.mainApp.unregister()
    }

    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
