import CryptoKit
import XCTest

@testable import TrackpadSwitchCore

private let studio = LinkPairing.PeerInfo(
  macName: "Studio", device: ManagedDevice(address: "aa-bb-cc-dd-ee-ff", name: "Magic Trackpad"))
private let laptop = LinkPairing.PeerInfo(macName: "Laptop", device: nil)

private func sends(_ outputs: [LinkPairing.Output]) -> [Data] {
  outputs.compactMap { if case .send(let data) = $0 { return data } else { return nil } }
}

private func digits(_ outputs: [LinkPairing.Output]) -> String? {
  outputs.lazy.compactMap { if case .compare(let digits) = $0 { return digits } else { return nil } }.first
}

private func link(_ outputs: [LinkPairing.Output]) -> LinkPairing.Link? {
  outputs.lazy.compactMap { if case .linked(let link) = $0 { return link } else { return nil } }.first
}

private func single(_ outputs: [LinkPairing.Output]) throws -> Data {
  try XCTUnwrap(sends(outputs).first)
}

private struct Session {
  let a = LinkPairing(role: .initiator, info: studio)
  let b = LinkPairing(role: .responder, info: laptop)
  var digitsA: String?
  var digitsB: String?

  mutating func compare() throws {
    let m2 = try single(b.receive(try a.start()))
    let m3 = try single(a.receive(m2))
    let fromB = try b.receive(m3)
    digitsB = digits(fromB)
    digitsA = digits(try a.receive(try XCTUnwrap(sends(fromB).first)))
  }
}

/// ECDH sample data from Linux's net/bluetooth/selftest.c (priv_a_1, pub_a_1, pub_b_1, dhkey_1), there least
/// significant octet first.
final class LinkPairingKeyTests: XCTestCase {
  func testKeyAgreementMatchesLinuxSelftest() throws {
    let privateA = try P256.KeyAgreement.PrivateKey(
      rawRepresentation: Data(hex: "3f49f6d4a3c55f3874c9b3e3d2103f504aff607beb40b7995899b8a6cd3c1abd"))
    XCTAssertEqual(
      privateA.publicKey.rawRepresentation,
      Data(
        hex: "20b003d2f297be2c5e2c83a7e9f9a5b9eff49111acf4fddbcc0301480e359de6"
          + "dc809c49652aeb6d63329abf5a52155c766345c28fed3024741c8ed01589d28b"))
    let publicB = try P256.KeyAgreement.PublicKey(
      rawRepresentation: Data(
        hex: "1ea1f0f01faf1d9609592284f19e4c0047b58afd8615a69f559077b22faaa190"
          + "4c55f33e429dad377356703a9ab85160472d1130e28e36765f89aff915b1214a"))
    let dhKey = try privateA.sharedSecretFromKeyAgreement(with: publicB).withUnsafeBytes { Data($0) }
    XCTAssertEqual(dhKey, Data(hex: "ec0234a357c8ad05341010a60a397d9b99796b13b4f866f1868d34f373bfa698"))
  }
}

final class LinkPairingTests: XCTestCase {
  func testBothSidesShowSameDigitsAndShareSecret() throws {
    var session = Session()
    try session.compare()
    XCTAssertEqual(session.digitsA?.count, 6)
    XCTAssertEqual(session.digitsA, session.digitsB)

    XCTAssertEqual(try session.b.receive(try single(session.a.confirm())), [])
    let fromB = try session.b.confirm()
    let linkB = try XCTUnwrap(link(fromB))
    let linkA = try XCTUnwrap(link(try session.a.receive(try XCTUnwrap(sends(fromB).first))))

    XCTAssertEqual(linkA.secret, linkB.secret)
    XCTAssertEqual(linkA.secret.count, LinkKey.secretLength)
    XCTAssertEqual(linkA.peer, laptop)
    XCTAssertEqual(linkB.peer, studio)
  }

  func testResponderMayConfirmFirst() throws {
    var session = Session()
    try session.compare()
    XCTAssertEqual(try session.b.confirm(), [])
    let fromB = try session.b.receive(try single(session.a.confirm()))
    let linkB = try XCTUnwrap(link(fromB))
    let linkA = try XCTUnwrap(link(try session.a.receive(try XCTUnwrap(sends(fromB).first))))
    XCTAssertEqual(linkA.secret, linkB.secret)
  }

  func testResponderStaysSilentUntilConfirmed() throws {
    var session = Session()
    try session.compare()
    XCTAssertEqual(try session.b.receive(try single(session.a.confirm())), [])
  }

  func testEachSessionDerivesNewSecret() throws {
    func run() throws -> Data {
      var session = Session()
      try session.compare()
      _ = try session.b.receive(try single(session.a.confirm()))
      return try XCTUnwrap(link(try session.b.confirm())).secret
    }
    XCTAssertNotEqual(try run(), try run())
  }

  func testKeySubstitutionShowsDifferentDigits() throws {
    let a = LinkPairing(role: .initiator, info: studio)
    let b = LinkPairing(role: .responder, info: laptop)
    let towardB = LinkPairing(role: .initiator, info: studio)
    let towardA = LinkPairing(role: .responder, info: laptop)

    let m2ForA = try single(towardA.receive(try a.start()))
    let m2FromB = try single(b.receive(try towardB.start()))
    let m3FromA = try single(a.receive(m2ForA))
    let fromB = try b.receive(try single(towardB.receive(m2FromB)))
    let fromAttacker = try towardA.receive(m3FromA)
    let digitsA = digits(try a.receive(try XCTUnwrap(sends(fromAttacker).first)))
    XCTAssertNotNil(digitsA)
    XCTAssertNotNil(digits(fromB))
    XCTAssertNotEqual(digitsA, digits(fromB))
  }

  func testRejectsCommitmentThatDoesNotMatchNonce() throws {
    let a = LinkPairing(role: .initiator, info: studio)
    let b = LinkPairing(role: .responder, info: laptop)
    var m2 = try single(b.receive(try a.start()))
    m2[m2.count - 1] ^= 1
    let m4 = try single(b.receive(try single(a.receive(m2))))
    XCTAssertThrowsError(try a.receive(m4)) { XCTAssertEqual($0 as? LinkPairing.Failure, .commitment) }
  }

  func testInitiatorRejectsAlteredResponderNonce() throws {
    let a = LinkPairing(role: .initiator, info: studio)
    let b = LinkPairing(role: .responder, info: laptop)
    let m3 = try single(a.receive(try single(b.receive(try a.start()))))
    var m4 = try single(b.receive(m3))
    m4[m4.count - 1] ^= 1
    XCTAssertThrowsError(try a.receive(m4)) { XCTAssertEqual($0 as? LinkPairing.Failure, .commitment) }
  }

  func testRejectsAlteredCheckValue() throws {
    var session = Session()
    try session.compare()
    var m5 = try single(session.a.confirm())
    m5[1] ^= 1
    _ = try session.b.receive(m5)
    XCTAssertThrowsError(try session.b.confirm()) { XCTAssertEqual($0 as? LinkPairing.Failure, .confirmation) }
  }

  func testRejectsAlteredPeerInfo() throws {
    var session = Session()
    try session.compare()
    var m5 = try single(session.a.confirm())
    m5[m5.count - 2] ^= 1
    XCTAssertEqual(try session.b.confirm(), [])
    XCTAssertThrowsError(try session.b.receive(m5)) { XCTAssertEqual($0 as? LinkPairing.Failure, .confirmation) }
  }

  func testRejectsReflectedPublicKey() throws {
    let a = LinkPairing(role: .initiator, info: studio)
    let b = LinkPairing(role: .responder, info: laptop)
    let m1 = try a.start()
    var reflected = try single(b.receive(m1))
    reflected.replaceSubrange(8..<72, with: m1.suffix(64))
    XCTAssertThrowsError(try a.receive(reflected)) { XCTAssertEqual($0 as? LinkPairing.Failure, .malformed) }
  }

  func testRejectsPointNotOnCurve() throws {
    var m1 = try LinkPairing(role: .initiator, info: studio).start()
    m1[m1.count - 1] ^= 1
    XCTAssertNoThrow(try P256.KeyAgreement.PublicKey(rawRepresentation: m1.suffix(64)))
    XCTAssertThrowsError(try LinkPairing(role: .responder, info: laptop).receive(m1)) {
      XCTAssertEqual($0 as? LinkPairing.Failure, .malformed)
    }
  }

  func testRejectsPointWithZeroY() throws {
    var m1 = try LinkPairing(role: .initiator, info: studio).start()
    m1.replaceSubrange(40..<72, with: Data(count: 32))
    XCTAssertThrowsError(try LinkPairing(role: .responder, info: laptop).receive(m1)) {
      XCTAssertEqual($0 as? LinkPairing.Failure, .malformed)
    }
  }

  func testRejectsOutOfOrderMessageAndStaysFailed() throws {
    let a = LinkPairing(role: .initiator, info: studio)
    let b = LinkPairing(role: .responder, info: laptop)
    let m1 = try a.start()
    XCTAssertThrowsError(try b.receive(Data([LinkPairing.Kind.initiatorNonce.rawValue]) + Data(count: 16))) {
      XCTAssertEqual($0 as? LinkPairing.Failure, .unexpected)
    }
    XCTAssertThrowsError(try b.receive(m1))
  }

  func testRejectsOversizedAndEmptyMessages() {
    let b = LinkPairing(role: .responder, info: laptop)
    XCTAssertThrowsError(try b.receive(Data(count: LinkPairing.maxMessageLength + 1)))
    XCTAssertThrowsError(try LinkPairing(role: .responder, info: laptop).receive(Data()))
  }

  func testConfirmBeforeComparisonFails() {
    XCTAssertThrowsError(try LinkPairing(role: .initiator, info: studio).confirm()) {
      XCTAssertEqual($0 as? LinkPairing.Failure, .unexpected)
    }
  }

  func testLimitsNamesInBytes() {
    let info = LinkPairing.PeerInfo(
      macName: String(repeating: "🇷🇴", count: 64),
      device: ManagedDevice(address: String(repeating: "a", count: 100), name: String(repeating: "x", count: 200)))
    XCTAssertLessThanOrEqual(info.macName.utf8.count, LinkPairing.PeerInfo.maxNameBytes)
    XCTAssertEqual(info.macName, String(repeating: "🇷🇴", count: 10))
    XCTAssertEqual(info.device?.name.utf8.count, LinkPairing.PeerInfo.maxNameBytes)
    XCTAssertEqual(info.device?.address.utf8.count, 32)
  }

  func testDropsControlCharacters() {
    XCTAssertEqual(LinkPairing.PeerInfo(macName: "Stu\u{0}di\no\u{7F}", device: nil).macName, "Studio")
  }

  func testLimitsDecodedNames() throws {
    let json = Data(#"{"macName":"\#(String(repeating: "x", count: 200))"}"#.utf8)
    let info = try JSONDecoder().decode(LinkPairing.PeerInfo.self, from: json)
    XCTAssertEqual(info.macName.utf8.count, LinkPairing.PeerInfo.maxNameBytes)
    XCTAssertNil(info.device)
  }

  func testWorstCaseNamesStillLink() throws {
    let escaped = String(repeating: "\"\\/", count: 40)
    let worst = LinkPairing.PeerInfo(
      macName: escaped, device: ManagedDevice(address: String(repeating: "/", count: 40), name: escaped))
    let a = LinkPairing(role: .initiator, info: worst)
    let b = LinkPairing(role: .responder, info: worst)
    let m3 = try single(a.receive(try single(b.receive(try a.start()))))
    _ = try a.receive(try single(b.receive(m3)))
    XCTAssertEqual(try b.receive(try single(a.confirm())), [])
    let fromB = try b.confirm()
    XCTAssertEqual(try XCTUnwrap(link(fromB)).peer, worst)
    XCTAssertEqual(try XCTUnwrap(link(try a.receive(try XCTUnwrap(sends(fromB).first)))).peer, worst)
  }

  func testRecognisesOnlyAnOpening() throws {
    let a = LinkPairing(role: .initiator, info: studio)
    let m1 = try a.start()
    XCTAssertTrue(LinkPairing.isOpening(m1))
    XCTAssertFalse(LinkPairing.isOpening(try single(LinkPairing(role: .responder, info: laptop).receive(m1))))
    XCTAssertFalse(LinkPairing.isOpening(m1.dropLast()))
    XCTAssertFalse(LinkPairing.isOpening(Data([1])))
  }
}
