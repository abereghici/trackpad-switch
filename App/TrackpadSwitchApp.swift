import KeyboardShortcuts
import SwiftUI
import TrackpadSwitchCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let peripherals = PeripheralController()
  let pairing = PairingLink()
  private(set) lazy var switcher = Switcher(
    bonds: peripherals, peers: PeerLink(), secrets: KeychainStore(), settings: SwitcherSettings(),
    notify: { Notifier.post("TrackpadSwitch", $0) })
  private let sleepMonitor = SleepMonitor()

  func applicationDidFinishLaunching(_ notification: Notification) {
    switcher.start()
    pairing.onLinked = { [weak self] link in
      MainActor.assumeIsolated { self?.switcher.link(link) ?? false }
    }
    peripherals.onConnectionChange = { [weak self] in
      Task { @MainActor in self?.switcher.refresh() }
    }
    peripherals.startObserving()
    sleepMonitor.onWillSleep = { [weak self] in
      MainActor.assumeIsolated { self?.switcher.handOffBeforeSleep() }
    }
    sleepMonitor.start()
    KeyboardShortcuts.onKeyUp(for: .toggleDevice) { [weak self] in
      Task { await self?.switcher.toggle() }
    }
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      switcher.handle(url)
    }
  }
}

@main
struct TrackpadSwitchApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    MenuBarExtra {
      MenuContent().environmentObject(appDelegate.switcher)
    } label: {
      MenuBarIcon(switcher: appDelegate.switcher)
    }
    Settings {
      SettingsView(peripherals: appDelegate.peripherals, pairing: appDelegate.pairing)
        .environmentObject(appDelegate.switcher)
    }
  }
}
