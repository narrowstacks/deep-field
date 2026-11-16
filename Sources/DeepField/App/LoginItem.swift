import ServiceManagement

/// Open at Login, through the system's login items.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on {
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } else {
                try service.unregister()
            }
        } catch {
            NSLog("DeepField: login item change failed: \(error)")
        }
    }
}
