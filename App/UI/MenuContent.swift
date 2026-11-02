import KeyboardShortcuts
import SwiftUI
import TrackpadSwitchCore

struct MenuBarIcon: View {
  @ObservedObject var switcher: Switcher

  var body: some View {
    Image(image)
      .accessibilityLabel(label)
  }

  private var image: String {
    guard switcher.device != nil else { return "MenuBarUnavailable" }
    if switcher.isBusy { return "MenuBarSwitching" }
    return switcher.holdsDevice ? "MenuBarHere" : "MenuBarElsewhere"
  }

  private var label: String {
    guard let device = switcher.device else { return "TrackpadSwitch, not set up" }
    if switcher.isBusy { return "TrackpadSwitch, switching \(device.name)" }
    return switcher.holdsDevice
      ? "TrackpadSwitch, \(device.name) is on this Mac" : "TrackpadSwitch, \(device.name) isn't on this Mac"
  }
}

struct MenuContent: View {
  @EnvironmentObject private var switcher: Switcher
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    if let device = switcher.device {
      let holdsDevice = switcher.holdsDevice
      Text(holdsDevice ? "\(device.name) is on this Mac" : "\(device.name) isn't on this Mac")
      switch switcher.activity {
      case .working(let status):
        Text(status)
      case .idle, .failed:
        if holdsDevice {
          if switcher.isLinked {
            Button("Send to \(peerName)") { Task { await switcher.send() } }
              .globalKeyboardShortcut(.toggleDevice)
          }
        } else {
          Button("Bring \(device.name) Here") { Task { await switcher.take() } }
            .globalKeyboardShortcut(.toggleDevice)
        }
      }
      if case .failed(let message) = switcher.activity {
        Text(message)
      }
      if !switcher.isLinked {
        Button("Link Your Other Mac…", action: showSettings)
      }
    } else {
      Button("Set Up TrackpadSwitch…", action: showSettings)
    }
    Divider()
    Button("About TrackpadSwitch") {
      NSApp.activate()
      NSApp.orderFrontStandardAboutPanel(nil)
    }
    Button("Settings…", action: showSettings)
      .keyboardShortcut(",")
    Divider()
    Button("Quit TrackpadSwitch") { NSApp.terminate(nil) }
      .keyboardShortcut("q")
  }

  private var peerName: String { switcher.peerName ?? "Other Mac" }

  private func showSettings() {
    NSApp.activate()
    openSettings()
  }
}
