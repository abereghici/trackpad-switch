import AppKit
import KeyboardShortcuts
import SwiftUI
import SystemConfiguration
import TrackpadSwitchCore

struct SettingsView: View {
  let peripherals: PeripheralController
  @ObservedObject var pairing: PairingLink
  @EnvironmentObject private var switcher: Switcher

  @State private var pairedDevices: [PairedDevice] = []
  @State private var launchAtLogin = LoginItem.isEnabled
  @State private var loginItemNeedsApproval = LoginItem.needsApproval
  @State private var confirmingUnlink = false

  var body: some View {
    Form {
      deviceSection
      linkSection
      Section("Shortcut") {
        KeyboardShortcuts.Recorder("Move device", name: .toggleDevice)
        Text("Raycast and scripts can open trackpadswitch://take, trackpadswitch://send or trackpadswitch://toggle.")
          .foregroundStyle(.secondary)
      }
      Section("Options") {
        Toggle("Hand the device to your other Mac when this Mac sleeps", isOn: $switcher.handOffOnSleep)
        Toggle("Launch at login", isOn: $launchAtLogin)
          .onChange(of: launchAtLogin) { _, enabled in
            LoginItem.isEnabled = enabled
            refreshLoginItem()
          }
        if loginItemNeedsApproval {
          HStack {
            Text("Allow TrackpadSwitch in Login Items to open it at login.")
              .foregroundStyle(.secondary)
            Spacer()
            Button("Open Login Items Settings…") { LoginItem.openSettings() }
          }
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 480)
    .onAppear(perform: reloadDevices)
    .onReceive(NotificationCenter.default.publisher(for: .pairedDevicesChanged)) { _ in reloadDevices() }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      reloadDevices()
      refreshLoginItem()
    }
  }

  // MARK: - Device

  private var deviceChoices: [PairedDevice] {
    guard let device = switcher.device, !pairedDevices.contains(where: { $0.address == device.address }) else {
      return pairedDevices
    }
    return pairedDevices + [PairedDevice(address: device.address, name: device.name, isConnected: false)]
  }

  @ViewBuilder
  private var deviceSection: some View {
    Section("Device") {
      if deviceChoices.isEmpty {
        Text(
          "Pair your trackpad, keyboard or mouse in System Settings › Bluetooth, or link a Mac that already uses it."
        )
        .foregroundStyle(.secondary)
      } else {
        Picker("Move", selection: deviceSelection) {
          if switcher.device == nil {
            Text("Choose…").tag(String?.none)
          }
          ForEach(deviceChoices) { device in
            Text(device.name).tag(Optional(device.address))
          }
        }
      }
    }
  }

  private var deviceSelection: Binding<String?> {
    Binding(
      get: { switcher.device?.address },
      set: { address in
        guard let choice = deviceChoices.first(where: { $0.address == address }) else { return }
        switcher.select(ManagedDevice(address: choice.address, name: choice.name))
      })
  }

  private func reloadDevices() {
    pairedDevices = peripherals.pairedDevices()
  }

  // MARK: - Other Mac

  @ViewBuilder
  private var linkSection: some View {
    Section("Other Mac") {
      if switcher.isLinked {
        LabeledContent("Linked with", value: switcher.peerName ?? "Other Mac")
        Button("Unlink…", role: .destructive) { confirmingUnlink = true }
          .confirmationDialog(
            "Unlink \(switcher.peerName ?? "Other Mac")?", isPresented: $confirmingUnlink
          ) {
            Button("Unlink", role: .destructive) {
              pairing.cancel()
              switcher.unlink()
            }
          } message: {
            Text(
              "Unlink it on \(switcher.peerName ?? "your other Mac") too. To move the device again, link both Macs again."
            )
          }
      } else {
        switch pairing.phase {
        case .idle, .linked:
          Text("Open TrackpadSwitch on your other Mac too, then click Link a Mac on both.")
            .foregroundStyle(.secondary)
          Button("Link a Mac", action: startLinking)
        case .searching:
          progress("Looking for your other Mac…")
        case .comparing(let digits):
          comparison(digits)
        case .waiting:
          progress("Waiting for your other Mac…")
        case .failed(let message):
          Text(message).foregroundStyle(.red)
          Button("Try Again", action: startLinking)
        }
      }
    }
  }

  private func progress(_ status: String) -> some View {
    HStack {
      ProgressView().controlSize(.small)
      Text(status)
      Spacer()
      Button("Cancel", action: pairing.cancel)
    }
  }

  @ViewBuilder
  private func comparison(_ digits: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("\(digits.prefix(3)) \(digits.suffix(3))")
        .font(.system(size: 34, weight: .semibold, design: .monospaced))
        .accessibilityLabel(digits.map(String.init).joined(separator: " "))
      Text("Check that your other Mac shows the same number.")
        .foregroundStyle(.secondary)
    }
    HStack {
      Spacer()
      Button("Doesn't Match", action: pairing.reject)
        .keyboardShortcut(.cancelAction)
      Button("They Match", action: pairing.confirm)
        .keyboardShortcut(.defaultAction)
    }
  }

  private func refreshLoginItem() {
    launchAtLogin = LoginItem.isEnabled
    loginItemNeedsApproval = LoginItem.needsApproval
  }

  private func startLinking() {
    let name = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac"
    pairing.start(info: LinkPairing.PeerInfo(macName: name, device: switcher.device))
  }
}
