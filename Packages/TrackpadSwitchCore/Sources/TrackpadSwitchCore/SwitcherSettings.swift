import Foundation

public struct ManagedDevice: Codable, Equatable, Sendable {
  public let address: String
  public let name: String

  public init(address: String, name: String) {
    self.address = address
    self.name = name
  }
}

public struct SwitcherSettings {
  private enum Key {
    static let deviceAddress = "device.address"
    static let deviceName = "device.name"
    static let handOffOnSleep = "handOffOnSleep"
    static let peerName = "peer.name"
  }

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public var device: ManagedDevice? {
    get {
      guard let address = defaults.string(forKey: Key.deviceAddress) else { return nil }
      return ManagedDevice(address: address, name: defaults.string(forKey: Key.deviceName) ?? address)
    }
    nonmutating set {
      defaults.set(newValue?.address, forKey: Key.deviceAddress)
      defaults.set(newValue?.name, forKey: Key.deviceName)
    }
  }

  public var peerName: String? {
    get { defaults.string(forKey: Key.peerName) }
    nonmutating set { defaults.set(newValue, forKey: Key.peerName) }
  }

  public var handOffOnSleep: Bool {
    get { defaults.object(forKey: Key.handOffOnSleep) as? Bool ?? true }
    nonmutating set { defaults.set(newValue, forKey: Key.handOffOnSleep) }
  }
}
