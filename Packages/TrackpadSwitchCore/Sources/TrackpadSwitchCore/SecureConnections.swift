import Crypto
import CryptoExtras
import Foundation

/// LE Secure Connections confirm, key and check functions, Bluetooth Core Specification v5.4, Vol 3, Part H, 2.2.6–2.2.9.
/// Byte strings are most significant octet first, as the specification writes them.
enum SecureConnections {
  typealias MAC = AES.CMAC.MAC

  private static let f5Salt = Data([
    0x6c, 0x88, 0x83, 0x91, 0xaa, 0xf5, 0xa5, 0x38, 0x60, 0x37, 0x0b, 0xdb, 0x5a, 0x60, 0x83, 0xbe,
  ])
  private static let f5KeyID = Data("btle".utf8)
  private static let f5Length = Data([0x01, 0x00])

  static func f4(u: Data, v: Data, x: Data, z: UInt8) throws -> MAC {
    try cmac(key: x, u + v + [z])
  }

  static func f5(w: Data, n1: Data, n2: Data, a1: Data, a2: Data) throws -> (macKey: Data, ltk: Data) {
    let t = Data(try cmac(key: f5Salt, w))
    func key(_ counter: UInt8) throws -> Data {
      Data(try cmac(key: t, Data([counter]) + f5KeyID + n1 + n2 + a1 + a2 + f5Length))
    }
    return (try key(0), try key(1))
  }

  static func f6(w: Data, n1: Data, n2: Data, r: Data, ioCap: Data, a1: Data, a2: Data) throws -> MAC {
    try cmac(key: w, n1 + n2 + r + ioCap + a1 + a2)
  }

  static func g2(u: Data, v: Data, x: Data, y: Data) throws -> UInt32 {
    let value = Data(try cmac(key: x, u + v + y)).suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    return value % 1_000_000
  }

  private static func cmac(key: Data, _ message: Data) throws -> MAC {
    var mac = try AES.CMAC(key: SymmetricKey(data: key))
    mac.update(data: message)
    return mac.finalize()
  }
}
