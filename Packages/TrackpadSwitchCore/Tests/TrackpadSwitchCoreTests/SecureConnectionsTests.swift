import XCTest

@testable import TrackpadSwitchCore

/// Sample data from Bluetooth Core Specification v5.4, Vol 3, Part H, Appendix D.2–D.5; the same values, least
/// significant octet first, are Linux's self-tests in net/bluetooth/smp.c (test_f4, test_f5, test_f6, test_g2).
final class SecureConnectionsTests: XCTestCase {
  let u = Data(hex: "20b003d2f297be2c5e2c83a7e9f9a5b9eff49111acf4fddbcc0301480e359de6")
  let v = Data(hex: "55188b3d32f6bb9a900afcfbeed4e72a59cb9ac2f19d7cfb6b4fdd49f47fc5fd")
  let n1 = Data(hex: "d5cb8454d177733effffb2ec712baeab")
  let n2 = Data(hex: "a6e8e7cc25a75f6e216583f7ff3dc4cf")
  let a1 = Data(hex: "0056123737bfce")
  let a2 = Data(hex: "00a713702dcfc1")

  func testF4() throws {
    let result = try SecureConnections.f4(u: u, v: v, x: n1, z: 0)
    XCTAssertEqual(Data(result), Data(hex: "f2c916f107a9bd1cf1eda1bea974872d"))
  }

  func testF5() throws {
    let w = Data(hex: "ec0234a357c8ad05341010a60a397d9b99796b13b4f866f1868d34f373bfa698")
    let keys = try SecureConnections.f5(w: w, n1: n1, n2: n2, a1: a1, a2: a2)
    XCTAssertEqual(keys.macKey, Data(hex: "2965f176a1084a02fd3f6a20ce636e20"))
    XCTAssertEqual(keys.ltk, Data(hex: "6986791169d7cd23980522b594750a38"))
  }

  func testF6() throws {
    let result = try SecureConnections.f6(
      w: Data(hex: "2965f176a1084a02fd3f6a20ce636e20"), n1: n1, n2: n2,
      r: Data(hex: "12a3343bb453bb5408da42d20c2d0fc8"), ioCap: Data(hex: "010102"), a1: a1, a2: a2)
    XCTAssertEqual(Data(result), Data(hex: "e3c473989cd0e8c5d26c0b09da958f61"))
  }

  func testG2() throws {
    XCTAssertEqual(try SecureConnections.g2(u: u, v: v, x: n1, y: n2), 0x2f9e_d5ba % 1_000_000)
  }
}

extension Data {
  init(hex: String) {
    self.init(
      stride(from: 0, to: hex.count, by: 2).map { offset in
        let start = hex.index(hex.startIndex, offsetBy: offset)
        return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
      })
  }
}
