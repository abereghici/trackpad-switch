import ServiceManagement

enum LoginItem {
  static var isEnabled: Bool {
    get { SMAppService.mainApp.status == .enabled }
    set {
      if newValue {
        try? SMAppService.mainApp.register()
      } else {
        try? SMAppService.mainApp.unregister()
      }
    }
  }

  static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

  static func openSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }
}
