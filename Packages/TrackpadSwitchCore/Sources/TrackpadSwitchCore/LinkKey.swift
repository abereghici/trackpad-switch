import CryptoKit
import Foundation

public struct LinkKey: Sendable {
  public static let secretLength = 16

  let key: SymmetricKey

  /// `secret`: the LTK from `LinkPairing`.
  public init?(secret: Data) {
    guard secret.count == Self.secretLength else { return nil }
    key = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: secret),
      salt: Data("trackpadswitch.link.v1".utf8),
      info: Data("hmac".utf8),
      outputByteCount: SHA256.byteCount)
  }

  /// 128-bit value for `CBUUID(data:)`.
  public var serviceID: Data { derive(label: "service").prefix(16) }
  /// 128-bit value for `CBUUID(data:)`.
  public var commandCharacteristicID: Data { derive(label: "command").prefix(16) }

  private func derive(label: String) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: Data("derive.\(label)".utf8), using: key))
  }
}
