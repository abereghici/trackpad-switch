import Foundation

public protocol DeviceBonding: Sendable {
  func isConnected(_ address: String) -> Bool
  func release(_ address: String) async -> Bool
  func acquire(_ address: String) async -> Bool
  /// The 6 bytes a `LinkMessage` carries for `address`.
  func wireAddress(_ address: String) -> Data?
  func address(fromWire bytes: Data) -> String?
}

public enum PeerOutcome: Equatable, Sendable {
  /// No linked Mac answered, or Bluetooth is unavailable on this Mac.
  case noPeer
  case delivered
  /// The peer refused the message: clocks too far apart, a replay, or a message it can't authenticate or decode.
  case rejected
  case failed
}

public protocol PeerMessaging: AnyObject, Sendable {
  /// The returned value is the acknowledgement sent back to the peer.
  var onMessage: (@Sendable (LinkMessage) async -> Bool)? { get set }
  func configure(key: LinkKey?)
  func send(_ kind: LinkMessage.Kind, address: Data) async -> PeerOutcome
}

public protocol SecretStore: Sendable {
  func loadLinkSecret() -> Data?
  func saveLinkSecret(_ secret: Data) -> Bool
  func deleteLinkSecret()
}
