import XCTest

@testable import TrackpadSwitchCore

private let fixedSecret = Data(0..<16)
private let address = Data([0xAA, 0xBB, 0xCC, 0x01, 0x02, 0x03])

private func hex(_ data: Data) -> String {
  data.map { String(format: "%02x", $0) }.joined()
}

/// Expected values were computed independently with Python's `hmac`/`hashlib` (RFC 5869 HKDF, then HMAC-SHA256).
final class LinkKeyTests: XCTestCase {
  func testMatchesIndependentlyComputedVectors() throws {
    let key = try XCTUnwrap(LinkKey(secret: fixedSecret))
    XCTAssertEqual(hex(key.serviceID), "0f431a124d11943b96028f73a80bcf2b")
    XCTAssertEqual(hex(key.commandCharacteristicID), "46a25a73f9575b3f713fbc1c9be4af4a")
  }

  func testDifferentSecretsDeriveDifferentIdentifiers() throws {
    let a = try XCTUnwrap(LinkKey(secret: fixedSecret))
    let b = try XCTUnwrap(LinkKey(secret: Data(repeating: 7, count: 16)))
    XCTAssertNotEqual(a.serviceID, b.serviceID)
    XCTAssertNotEqual(a.commandCharacteristicID, b.commandCharacteristicID)
  }

  func testRejectsSecretOfWrongLength() {
    XCTAssertNil(LinkKey(secret: Data(count: 15)))
    XCTAssertNil(LinkKey(secret: Data(count: 17)))
  }
}

final class LinkMessageTests: XCTestCase {
  func key() throws -> LinkKey { try XCTUnwrap(LinkKey(secret: fixedSecret)) }

  func sample(_ kind: LinkMessage.Kind = .release) throws -> LinkMessage {
    try XCTUnwrap(LinkMessage(kind: kind, address: address))
  }

  func testMatchesIndependentlyComputedEncoding() throws {
    let message = try XCTUnwrap(
      LinkMessage(kind: .take, address: address, timestamp: 1_800_000_000, nonce: 0x0102_0304_0506_0708))
    XCTAssertEqual(
      hex(message.encoded(with: try key())),
      "0102aabbcc010203000000006b49d2000102030405060708"
        + "5ce3126ed88f4c8362325605afb2eabc75edc8bb65dad566a96480d989f4bebb")
  }

  func testRoundTrip() throws {
    let message = try XCTUnwrap(
      LinkMessage(kind: .take, address: address, timestamp: 1_800_000_000, nonce: 0x0102_0304_0506_0708))
    let data = message.encoded(with: try key())
    XCTAssertEqual(data.count, LinkMessage.encodedLength)
    XCTAssertEqual(try LinkMessage.decode(data, with: try key()), message)
  }

  func testRejectsAddressOfWrongLength() {
    XCTAssertNil(LinkMessage(kind: .release, address: Data([1, 2, 3, 4, 5])))
  }

  func testRejectsEveryFlippedBit() throws {
    let data = try sample().encoded(with: try key())
    for byte in 0..<data.count {
      for bit in 0..<8 {
        var tampered = data
        tampered[byte] ^= UInt8(1 << bit)
        XCTAssertThrowsError(try LinkMessage.decode(tampered, with: try key())) { error in
          XCTAssertEqual(error as? LinkMessage.DecodeError, .authentication)
        }
      }
    }
  }

  func testRejectsOtherKey() throws {
    let data = try sample().encoded(with: try key())
    let other = try XCTUnwrap(LinkKey(secret: Data(repeating: 7, count: 16)))
    XCTAssertThrowsError(try LinkMessage.decode(data, with: other))
  }

  func testRejectsWrongLength() throws {
    let data = try sample().encoded(with: try key())
    XCTAssertThrowsError(try LinkMessage.decode(data.dropLast(), with: try key())) { error in
      XCTAssertEqual(error as? LinkMessage.DecodeError, .length)
    }
    XCTAssertThrowsError(try LinkMessage.decode(data + Data([0]), with: try key()))
  }

  func testDecodesFromNonZeroBasedSlice() throws {
    let message = try sample()
    let padded = Data([0xFF]) + message.encoded(with: try key())
    XCTAssertEqual(try LinkMessage.decode(padded.dropFirst(), with: try key()), message)
  }
}

final class ReplayGuardTests: XCTestCase {
  func message(at timestamp: UInt64, nonce: UInt64) -> LinkMessage {
    LinkMessage(kind: .release, address: address, timestamp: timestamp, nonce: nonce)!
  }

  func testAcceptsOnceThenRejectsReplay() {
    var guardian = ReplayGuard(window: 30)
    XCTAssertEqual(guardian.check(message(at: 1000, nonce: 1), now: 1000), .accepted)
    XCTAssertEqual(guardian.check(message(at: 1000, nonce: 1), now: 1010), .replayed)
    XCTAssertEqual(guardian.check(message(at: 1000, nonce: 2), now: 1010), .accepted)
  }

  func testRejectsOutsideWindowBothDirections() {
    var guardian = ReplayGuard(window: 30)
    XCTAssertEqual(guardian.check(message(at: 1000, nonce: 1), now: 1031), .stale)
    XCTAssertEqual(guardian.check(message(at: 1031, nonce: 2), now: 1000), .stale)
    XCTAssertEqual(guardian.check(message(at: 1030, nonce: 3), now: 1000), .accepted)
  }

  func testReplayOfPrunedNonceIsStillRejectedAsStale() {
    var guardian = ReplayGuard(window: 30)
    XCTAssertEqual(guardian.check(message(at: 1000, nonce: 1), now: 1000), .accepted)
    XCTAssertEqual(guardian.check(message(at: 1100, nonce: 2), now: 1100), .accepted)
    XCTAssertEqual(guardian.trackedCount, 1)
    XCTAssertEqual(guardian.check(message(at: 1000, nonce: 1), now: 1100), .stale)
  }
}
