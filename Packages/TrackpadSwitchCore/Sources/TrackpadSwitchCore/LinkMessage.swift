import CryptoKit
import Foundation

public struct LinkMessage: Equatable, Sendable {
  public enum Kind: UInt8, Sendable {
    /// Receiver releases `address`: unpairs it, or disconnects it if it can't unpair.
    case release = 1
    /// Sender already holds `address` and will release it right after the ack; receiver pairs it.
    case take = 2
  }

  public enum DecodeError: Error, Equatable {
    case length, authentication, version, kind
  }

  public static let version: UInt8 = 1
  public static let addressLength = 6
  static let bodyLength = 2 + addressLength + 8 + 8
  public static let encodedLength = bodyLength + SHA256.byteCount

  public let kind: Kind
  /// The 6 bytes of a `BluetoothDeviceAddress`.
  public let address: Data
  public let timestamp: UInt64
  public let nonce: UInt64

  public init?(kind: Kind, address: Data, timestamp: UInt64, nonce: UInt64) {
    guard address.count == Self.addressLength else { return nil }
    self.kind = kind
    self.address = Data(address)
    self.timestamp = timestamp
    self.nonce = nonce
  }

  public init?(kind: Kind, address: Data, date: Date = Date()) {
    self.init(
      kind: kind, address: address, timestamp: UInt64(date.timeIntervalSince1970),
      nonce: .random(in: .min ... .max))
  }

  public func encoded(with key: LinkKey) -> Data {
    var body = Data([Self.version, kind.rawValue])
    body.append(address)
    withUnsafeBytes(of: timestamp.bigEndian) { body.append(contentsOf: $0) }
    withUnsafeBytes(of: nonce.bigEndian) { body.append(contentsOf: $0) }
    return body + Data(HMAC<SHA256>.authenticationCode(for: body, using: key.key))
  }

  public static func decode(_ payload: Data, with key: LinkKey) throws -> LinkMessage {
    let data = Data(payload)
    guard data.count == encodedLength else { throw DecodeError.length }
    guard
      HMAC<SHA256>.isValidAuthenticationCode(
        data.suffix(from: bodyLength), authenticating: data.prefix(bodyLength), using: key.key)
    else { throw DecodeError.authentication }
    guard data[0] == version else { throw DecodeError.version }
    guard let kind = Kind(rawValue: data[1]) else { throw DecodeError.kind }
    let (timestamp, nonce) = data.withUnsafeBytes { bytes in
      (
        UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt64.self)),
        UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: 16, as: UInt64.self))
      )
    }
    return LinkMessage(kind: kind, address: data[2..<8], timestamp: timestamp, nonce: nonce)!
  }
}
