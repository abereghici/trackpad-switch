import Foundation
import IOBluetooth
import TrackpadSwitchCore
import os

extension Notification.Name {
  static let pairedDevicesChanged = Notification.Name("dev.bereghici.trackpadswitch.pairedDevicesChanged")
}

struct PairedDevice: Identifiable, Hashable {
  let address: String
  let name: String
  let isConnected: Bool
  var id: String { address }
}

final class PeripheralController: NSObject, @unchecked Sendable {
  static let pairTimeout: TimeInterval = 60
  static let unbondSettle: TimeInterval = 0.5

  var onConnectionChange: (() -> Void)?

  private struct Pending {
    let pair: IOBluetoothDevicePair
    let started: ContinuousClock.Instant
    let done: (Bool) -> Void
  }

  private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "trackpadswitch", category: "device")

  private let queue = DispatchQueue(label: "trackpadswitch.bluetooth")
  private let lock = NSLock()
  private var pendingPairs: [String: Pending] = [:]
  private var connectObserver: IOBluetoothUserNotification?
  private var disconnectObservers: [String: IOBluetoothUserNotification] = [:]

  func startObserving() {
    connectObserver = IOBluetoothDevice.register(
      forConnectNotifications: self, selector: #selector(deviceConnected(_:fromDevice:)))
    for device in IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [] where device.isConnected() {
      observeDisconnect(of: device)
    }
  }

  /// Major device class Peripheral (keyboards, mice, trackpads, joysticks), plus Miscellaneous and Unclassified: the
  /// class "is only meaningful if the target device has been seen during an inquiry" (IOBluetoothDevice.h).
  func pairedDevices() -> [PairedDevice] {
    let classes = [
      kBluetoothDeviceClassMajorPeripheral, kBluetoothDeviceClassMajorMiscellaneous,
      kBluetoothDeviceClassMajorUnclassified,
    ].map(BluetoothDeviceClassMajor.init)
    let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
    return devices.compactMap { device in
      guard classes.contains(device.deviceClassMajor), let address = device.addressString else { return nil }
      return PairedDevice(address: address, name: device.name ?? address, isConnected: device.isConnected())
    }
  }

  func isConnected(_ address: String) -> Bool {
    DeviceAddress.device(address)?.isConnected() ?? false
  }

  func release(_ address: String) async -> Bool {
    await withCheckedContinuation { continuation in
      queue.async {
        guard let device = DeviceAddress.device(address),
          device.isPaired() || device.isConnected()
        else {
          continuation.resume(returning: true)
          return
        }
        if Self.removeBond(device) {
          continuation.resume(returning: true)
        } else {
          continuation.resume(returning: device.closeConnection() == kIOReturnSuccess)
        }
      }
    }
  }

  func acquire(_ address: String) async -> Bool {
    await withCheckedContinuation { continuation in
      queue.async {
        self.performAcquire(address) { continuation.resume(returning: $0) }
      }
    }
  }

  private func performAcquire(_ address: String, done: @escaping (Bool) -> Void) {
    guard let device = DeviceAddress.device(address), let key = device.addressString, pending(for: key) == nil else {
      done(false)
      return
    }
    if device.isConnected() {
      done(true)
      return
    }
    guard device.isPaired() else {
      startPair(device, key: key, done: done)
      return
    }
    let opening = ContinuousClock.now
    let opened = device.openConnection()
    log.notice(
      "open existing bond: \(UInt32(bitPattern: opened), format: .hex, privacy: .public) in \(opening.duration(to: .now), privacy: .public)"
    )
    if device.isConnected() {
      done(true)
      return
    }
    guard Self.removeBond(device) else {
      done(false)
      return
    }
    queue.asyncAfter(deadline: .now() + Self.unbondSettle) {
      self.startPair(DeviceAddress.device(key) ?? device, key: key, done: done)
    }
  }

  private func startPair(_ device: IOBluetoothDevice, key: String, done: @escaping (Bool) -> Void) {
    guard let pair = IOBluetoothDevicePair(device: device) else {
      done(false)
      return
    }
    pair.delegate = self
    setPending(Pending(pair: pair, started: .now, done: done), for: key)
    let started = pair.start()
    guard started == kIOReturnSuccess else {
      log.error("pairing did not start: \(UInt32(bitPattern: started), format: .hex, privacy: .public)")
      if takePending(for: key, matching: pair) != nil { done(false) }
      return
    }
    queue.asyncAfter(deadline: .now() + Self.pairTimeout) { [weak self] in
      guard let pending = self?.takePending(for: key, matching: pair) else { return }
      self?.log.error("pairing timed out after \(pending.started.duration(to: .now), privacy: .public)")
      pair.stop()
      pending.done(false)
    }
  }

  private static func removeBond(_ device: IOBluetoothDevice) -> Bool {
    // Private selector, the call behind blueutil `--unpair` (toy/blueutil, blueutil.m, `case arg_unpair`).
    let selector = Selector(("remove"))
    guard device.responds(to: selector) else { return false }
    device.perform(selector)
    return true
  }

  private func pending(for key: String) -> Pending? {
    lock.withLock { pendingPairs[key] }
  }

  private func setPending(_ pending: Pending, for key: String) {
    lock.withLock { pendingPairs[key] = pending }
  }

  private func takePending(for key: String, matching pair: IOBluetoothDevicePair) -> Pending? {
    lock.withLock {
      guard let pending = pendingPairs[key], pending.pair === pair else { return nil }
      pendingPairs[key] = nil
      return pending
    }
  }

  private static func pairAndKey(_ sender: Any?) -> (pair: IOBluetoothDevicePair, key: String)? {
    guard let pair = sender as? IOBluetoothDevicePair, let key = pair.device()?.addressString else {
      return nil
    }
    return (pair: pair, key: key)
  }

  private func isOurs(_ sender: Any?) -> Bool {
    guard let match = Self.pairAndKey(sender) else { return false }
    return pending(for: match.key)?.pair === match.pair
  }

  @objc(devicePairingFinished:error:)
  func devicePairingFinished(_ sender: Any?, error: IOReturn) {
    guard let match = Self.pairAndKey(sender),
      let pending = takePending(for: match.key, matching: match.pair)
    else { return }
    let pair = match.pair
    log.notice(
      "pairing: \(UInt32(bitPattern: error), format: .hex, privacy: .public) in \(pending.started.duration(to: .now), privacy: .public)"
    )
    guard error == kIOReturnSuccess, let device = pair.device() else {
      pending.done(false)
      return
    }
    queue.async {
      if !device.isConnected() {
        let opening = ContinuousClock.now
        let opened = device.openConnection()
        self.log.notice(
          "open after pairing: \(UInt32(bitPattern: opened), format: .hex, privacy: .public) in \(opening.duration(to: .now), privacy: .public)"
        )
      }
      pending.done(device.isConnected())
    }
  }

  @objc(devicePairingUserConfirmationRequest:numericValue:)
  func devicePairingUserConfirmationRequest(_ sender: Any?, numericValue: BluetoothNumericValue) {
    (sender as? IOBluetoothDevicePair)?.replyUserConfirmation(isOurs(sender))
  }

  @objc(devicePairingPINCodeRequest:)
  func devicePairingPINCodeRequest(_ sender: Any?) {
    guard isOurs(sender), let pair = sender as? IOBluetoothDevicePair else { return }
    var code = BluetoothPINCode()
    let digits = Array("0000".utf8)
    withUnsafeMutableBytes(of: &code.data) { raw in
      for (index, byte) in digits.enumerated() { raw[index] = byte }
    }
    pair.replyPINCode(digits.count, pinCode: &code)
  }

  @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, fromDevice device: IOBluetoothDevice)
  {
    observeDisconnect(of: device)
    connectionChanged()
  }

  private func observeDisconnect(of device: IOBluetoothDevice) {
    guard let key = device.addressString else { return }
    disconnectObservers[key]?.unregister()
    disconnectObservers[key] = device.register(
      forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:fromDevice:)))
  }

  @objc private func deviceDisconnected(
    _ notification: IOBluetoothUserNotification, fromDevice device: IOBluetoothDevice
  ) {
    notification.unregister()
    if let key = device.addressString {
      disconnectObservers[key] = nil
    }
    connectionChanged()
  }

  private func connectionChanged() {
    onConnectionChange?()
    NotificationCenter.default.post(name: .pairedDevicesChanged, object: self)
  }
}

extension PeripheralController: DeviceBonding {
  func wireAddress(_ address: String) -> Data? {
    DeviceAddress.bytes(address)
  }

  func address(fromWire bytes: Data) -> String? {
    DeviceAddress.string(bytes)
  }
}
