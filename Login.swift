import ServiceManagement

// Without this the app dies on every reboot and auto mode quietly stops
// working: hooks still write claims, but nobody reads them.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns nil on success, or a short message to surface in the panel.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            // Most often because the app is running from a build directory
            // rather than /Applications.
            return "Login item failed: \(error.localizedDescription)"
        }
    }
}
