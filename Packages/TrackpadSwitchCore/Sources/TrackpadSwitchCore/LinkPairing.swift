import Crypto
import Foundation

/// Links two Macs with LE Secure Connections numeric comparison (Bluetooth Core Specification v5.4, Vol 3, Part H,
/// 2.3.5.6.2 and 2.3.5.6.5), carried in TrackpadSwitch's own messages instead of SMP. The people at both Macs compare the
/// 6 digits and confirm; the resulting LTK becomes the link secret.
public final class LinkPairing {
  public enum Role: Sendable {
    case initiator, responder
  }

  public struct PeerInfo: Codable, Equatable, Sendable {
    /// UTF-8 bytes kept of each name; with JSON escaping at most doubling them, the check message stays within
    /// `maxMessageLength` (`testWorstCaseNamesStillLink`).
    public static let maxNameBytes = 80
    static let maxAddressBytes = 32

    public let macName: String
    public let device: ManagedDevice?

    public init(macName: String, device: ManagedDevice?) {
      self.macName = Self.limited(macName, to: Self.maxNameBytes)
      self.device = device.map {
        ManagedDevice(
          address: Self.limited($0.address, to: Self.maxAddressBytes),
          name: Self.limited($0.name, to: Self.maxNameBytes))
      }
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.init(
        macName: try container.decode(String.self, forKey: .macName),
        device: try container.decodeIfPresent(ManagedDevice.self, forKey: .device))
    }

    /// Drops control characters, which JSON escapes to up to 6 bytes each, then whole characters until `bytes` UTF-8 bytes fit.
    static func limited(_ text: String, to bytes: Int) -> String {
      var result = String(
        String.UnicodeScalarView(text.unicodeScalars.filter { $0.properties.generalCategory != .control }))
      while result.utf8.count > bytes { result.removeLast() }
      return result
    }
  }

  public struct Link: Equatable, Sendable {
    public let secret: Data
    public let peer: PeerInfo
  }

  public enum Output: Equatable {
    case send(Data)
    case compare(String)
    case linked(Link)
  }

  public enum Failure: Error, Equatable {
    case malformed, unexpected, commitment, confirmation
  }

  /// Largest ATT attribute value (Bluetooth Core Specification v5.4, Vol 3, Part F, 3.2.9).
  public static let maxMessageLength = 512

  public static func isOpening(_ data: Data) -> Bool {
    data.count == 1 + addressLength + keyLength && data.first == Kind.publicKey.rawValue
  }

  enum Kind: UInt8 {
    case publicKey = 1, publicKeyAndCommitment, initiatorNonce, responderNonce, initiatorCheck, responderCheck
  }

  private enum Step {
    case idle, awaitingKey, awaitingNonce, comparing, confirmed, awaitingCheck, done, failed
  }

  private struct Party {
    let x: Data
    let nonce: Data
    let address: Data
  }

  /// AuthReq (bonding, MITM, SC), OOB data flag, IO capability DisplayYesNo (Vol 3, Part H, 3.5.1).
  static let ioCap = Data([0x0D, 0x00, 0x01])
  private static let addressLength = 7
  private static let keyLength = 64
  private static let valueLength = 16
  private static let tagLength = SHA256.byteCount

  public let role: Role
  private let info: PeerInfo
  private let privateKey: P256.KeyAgreement.PrivateKey
  private let own: Party
  private var step: Step
  private var peerKey: P256.KeyAgreement.PublicKey?
  private var peerAddress: Data?
  private var peerNonce: Data?
  private var peerCommitment: Data?
  private var heldCheck: Data?
  private var keys: (macKey: Data, ltk: Data)?

  public convenience init(role: Role, info: PeerInfo) {
    self.init(
      role: role, info: info, privateKey: P256.KeyAgreement.PrivateKey(),
      nonce: Self.random(Self.valueLength), address: Data([0x01]) + Self.random(Self.addressLength - 1))
  }

  init(role: Role, info: PeerInfo, privateKey: P256.KeyAgreement.PrivateKey, nonce: Data, address: Data) {
    self.role = role
    self.info = info
    self.privateKey = privateKey
    own = Party(x: privateKey.publicKey.rawRepresentation.prefix(32), nonce: nonce, address: address)
    step = role == .initiator ? .idle : .awaitingKey
  }

  public func start() throws -> Data {
    guard role == .initiator, step == .idle else { throw fail(.unexpected) }
    step = .awaitingKey
    return Self.message(.publicKey, own.address + privateKey.publicKey.rawRepresentation)
  }

  public func receive(_ data: Data) throws -> [Output] {
    do {
      return try handle(Data(data))
    } catch let failure as Failure {
      throw fail(failure)
    } catch {
      throw fail(.malformed)
    }
  }

  public func confirm() throws -> [Output] {
    do {
      switch (role, step) {
      case (.initiator, .comparing):
        let keys = try sessionKeys()
        step = .awaitingCheck
        return [.send(try checkMessage(.initiatorCheck, keys: keys))]
      case (.responder, .comparing):
        step = .confirmed
        guard let heldCheck else { return [] }
        return try answer(heldCheck)
      default:
        throw Failure.unexpected
      }
    } catch let failure as Failure {
      throw fail(failure)
    } catch {
      throw fail(.malformed)
    }
  }

  // MARK: - Steps

  private func handle(_ data: Data) throws -> [Output] {
    guard step != .failed, data.count <= Self.maxMessageLength, let first = data.first,
      let kind = Kind(rawValue: first)
    else { throw Failure.malformed }
    let body = Data(data.dropFirst())
    switch (role, step, kind) {
    case (.responder, .awaitingKey, .publicKey):
      guard body.count == Self.addressLength + Self.keyLength else { throw Failure.malformed }
      try acceptPeer(address: body.prefix(Self.addressLength), key: body.suffix(Self.keyLength))
      let commitment = try SecureConnections.f4(u: own.x, v: try peerX(), x: own.nonce, z: 0)
      step = .awaitingNonce
      return [
        .send(
          Self.message(
            .publicKeyAndCommitment, own.address + privateKey.publicKey.rawRepresentation + Data(commitment)))
      ]

    case (.initiator, .awaitingKey, .publicKeyAndCommitment):
      guard body.count == Self.addressLength + Self.keyLength + Self.valueLength else { throw Failure.malformed }
      try acceptPeer(
        address: body.prefix(Self.addressLength),
        key: body.dropFirst(Self.addressLength).prefix(Self.keyLength))
      peerCommitment = body.suffix(Self.valueLength)
      step = .awaitingNonce
      return [.send(Self.message(.initiatorNonce, own.nonce))]

    case (.responder, .awaitingNonce, .initiatorNonce):
      guard body.count == Self.valueLength else { throw Failure.malformed }
      peerNonce = body
      step = .comparing
      return [.send(Self.message(.responderNonce, own.nonce)), .compare(try digits())]

    case (.initiator, .awaitingNonce, .responderNonce):
      guard body.count == Self.valueLength, let peerCommitment else { throw Failure.malformed }
      guard try SecureConnections.f4(u: try peerX(), v: own.x, x: body, z: 0) == peerCommitment else {
        throw Failure.commitment
      }
      peerNonce = body
      step = .comparing
      return [.compare(try digits())]

    case (.responder, .comparing, .initiatorCheck):
      heldCheck = body
      return []

    case (.responder, .confirmed, .initiatorCheck):
      return try answer(body)

    case (.initiator, .awaitingCheck, .responderCheck):
      guard let keys else { throw Failure.unexpected }
      let peerInfo = try verifyCheck(body, keys: keys)
      step = .done
      return [.linked(Link(secret: keys.ltk, peer: peerInfo))]

    default:
      throw Failure.unexpected
    }
  }

  private func answer(_ check: Data) throws -> [Output] {
    let keys = try sessionKeys()
    let peerInfo = try verifyCheck(check, keys: keys)
    let reply = try checkMessage(.responderCheck, keys: keys)
    step = .done
    return [.send(reply), .linked(Link(secret: keys.ltk, peer: peerInfo))]
  }

  // MARK: - Values

  private func acceptPeer(address: Data, key: Data) throws {
    guard key != privateKey.publicKey.rawRepresentation else { throw Failure.malformed }
    // `init(rawRepresentation:)` accepts points off the curve; the SEC1 uncompressed form is validated.
    peerKey = try P256.KeyAgreement.PublicKey(x963Representation: Data([0x04]) + key)
    peerAddress = address
  }

  private func peerX() throws -> Data {
    guard let peerKey else { throw Failure.unexpected }
    return peerKey.rawRepresentation.prefix(32)
  }

  private func peerParty() throws -> Party {
    guard let peerAddress, let peerNonce else { throw Failure.unexpected }
    return Party(x: try peerX(), nonce: peerNonce, address: peerAddress)
  }

  private func roles() throws -> (a: Party, b: Party) {
    let peer = try peerParty()
    return role == .initiator ? (own, peer) : (peer, own)
  }

  private func digits() throws -> String {
    let (a, b) = try roles()
    let value = try SecureConnections.g2(u: a.x, v: b.x, x: a.nonce, y: b.nonce)
    return String(format: "%06u", value)
  }

  private func sessionKeys() throws -> (macKey: Data, ltk: Data) {
    if let keys { return keys }
    guard let peerKey else { throw Failure.unexpected }
    let dhKey = try privateKey.sharedSecretFromKeyAgreement(with: peerKey).withUnsafeBytes { Data($0) }
    let (a, b) = try roles()
    let keys = try SecureConnections.f5(w: dhKey, n1: a.nonce, n2: b.nonce, a1: a.address, a2: b.address)
    self.keys = keys
    return keys
  }

  /// Ea = f6(MacKey, Na, Nb, rb, IOcapA, A, B) and Eb = f6(MacKey, Nb, Na, ra, IOcapB, B, A); r is zero in
  /// numeric comparison.
  private func checkValue(from sender: Party, to receiver: Party, macKey: Data) throws -> SecureConnections.MAC {
    try SecureConnections.f6(
      w: macKey, n1: sender.nonce, n2: receiver.nonce, r: Data(count: Self.valueLength), ioCap: Self.ioCap,
      a1: sender.address, a2: receiver.address)
  }

  private func checkMessage(_ kind: Kind, keys: (macKey: Data, ltk: Data)) throws -> Data {
    let peer = try peerParty()
    let check = try checkValue(from: own, to: peer, macKey: keys.macKey)
    let encoded = try JSONEncoder().encode(info)
    let tag = HMAC<SHA256>.authenticationCode(for: [kind.rawValue] + encoded, using: Self.infoKey(keys.ltk))
    let message = Self.message(kind, Data(check) + Data(tag) + encoded)
    guard message.count <= Self.maxMessageLength else { throw Failure.malformed }
    return message
  }

  private func verifyCheck(_ body: Data, keys: (macKey: Data, ltk: Data)) throws -> PeerInfo {
    guard body.count > Self.valueLength + Self.tagLength else { throw Failure.malformed }
    let peer = try peerParty()
    guard try checkValue(from: peer, to: own, macKey: keys.macKey) == body.prefix(Self.valueLength) else {
      throw Failure.confirmation
    }
    let tag = body.dropFirst(Self.valueLength).prefix(Self.tagLength)
    let encoded = Data(body.dropFirst(Self.valueLength + Self.tagLength))
    let kind: Kind = role == .initiator ? .responderCheck : .initiatorCheck
    guard
      HMAC<SHA256>.isValidAuthenticationCode(
        tag, authenticating: [kind.rawValue] + encoded, using: Self.infoKey(keys.ltk))
    else { throw Failure.confirmation }
    return try JSONDecoder().decode(PeerInfo.self, from: encoded)
  }

  private static func infoKey(_ ltk: Data) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: ltk), salt: Data("trackpadswitch.pair.v1".utf8),
      info: Data("peer-info".utf8),
      outputByteCount: SHA256.byteCount)
  }

  private func fail(_ failure: Failure) -> Failure {
    step = .failed
    return failure
  }

  private static func message(_ kind: Kind, _ body: Data) -> Data {
    Data([kind.rawValue]) + body
  }

  private static func random(_ count: Int) -> Data {
    SymmetricKey(size: .init(bitCount: count * 8)).withUnsafeBytes { Data($0) }
  }
}
