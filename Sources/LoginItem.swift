import Foundation
import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Sync login-item with setting. Returns user-facing warning if enable failed.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        if enabled == isEnabled { return nil }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            if enabled {
                return """
                macOS не разрешил автозапуск. Открой Системные настройки → Основные → Объекты входа и добавь Touch вручную. \
                У локальной сборки без подписи Apple эта кнопка часто недоступна — CONNECT при старте всё равно работает, если открыть приложение.
                """
            }
            return nil
        }
    }
}
