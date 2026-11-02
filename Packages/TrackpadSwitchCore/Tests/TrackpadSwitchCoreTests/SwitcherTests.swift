import Combine
import XCTest

@testable import TrackpadSwitchCore

private let trackpad = ManagedDevice(address: "dev001", name: "Trackpad")

private final class FakeBonds: DeviceBonding, @unchecked Sendable {
  private let lock = NSLock()
  private var connected: Set<String>
  private var log: [String] = []
  private let acquireSucceeds: Bool

  init(holding: Bool, acquireSucceeds: Bool = true) {
    connected = holding ? [trackpad.address] : []
    self.acquireSucceeds = acquireSucceeds
  }

  var calls: [String] { lock.withLock { log } }

  func isConnected(_ address: String) -> Bool { lock.withLock { connected.contains(address) } }

  func release(_ address: String) async -> Bool {
    lock.withLock {
      log.append("release \(address)")
      _ = connected.remove(address)
    }
    return true
  }

  func acquire(_ address: String) async -> Bool {
    lock.withLock {
      log.append("acquire \(address)")
      if acquireSucceeds { _ = connected.insert(address) }
    }
    return acquireSucceeds
  }

  func wireAddress(_ address: String) -> Data? { Data(address.utf8) }
  func address(fromWire bytes: Data) -> String? { String(decoding: bytes, as: UTF8.self) }
}

private final class FakePeers: PeerMessaging, @unchecked Sendable {
  var onMessage: (@Sendable (LinkMessage) async -> Bool)?
  private let lock = NSLock()
  private var sent: [LinkMessage.Kind] = []
  private let outcome: PeerOutcome

  init(answering outcome: PeerOutcome) {
    self.outcome = outcome
  }

  var sentKinds: [LinkMessage.Kind] { lock.withLock { sent } }

  func configure(key: LinkKey?) {}

  func send(_ kind: LinkMessage.Kind, address: Data) async -> PeerOutcome {
    lock.withLock { sent.append(kind) }
    return outcome
  }
}

final class MemorySecrets: SecretStore, @unchecked Sendable {
  private let lock = NSLock()
  private var secret: Data?

  init(secret: Data?) {
    self.secret = secret
  }

  var stored: Data? { lock.withLock { secret } }

  func loadLinkSecret() -> Data? { lock.withLock { secret } }
  func saveLinkSecret(_ secret: Data) -> Bool { lock.withLock { self.secret = secret }; return true }
  func deleteLinkSecret() { lock.withLock { secret = nil } }
}

private final class Notes: @unchecked Sendable {
  var items: [String] = []
}

@MainActor
private final class Harness {
  let bonds: FakeBonds
  let peers: FakePeers
  let switcher: Switcher
  let secrets: MemorySecrets
  let settings: SwitcherSettings
  private let notes: Notes
  private(set) var activities: [Switcher.Activity] = []
  private var activitySubscription: AnyCancellable?

  var notifications: [String] { notes.items }

  init(
    holding: Bool, peer outcome: PeerOutcome, linked: Bool = true, acquireSucceeds: Bool = true,
    device: ManagedDevice? = trackpad
  ) {
    let bonds = FakeBonds(holding: holding, acquireSucceeds: acquireSucceeds)
    let peers = FakePeers(answering: outcome)
    self.bonds = bonds
    self.peers = peers
    let defaults = UserDefaults(suiteName: "TrackpadSwitchCoreTests")!
    defaults.removePersistentDomain(forName: "TrackpadSwitchCoreTests")
    let settings = SwitcherSettings(defaults: defaults)
    settings.device = device
    self.settings = settings
    let secrets = MemorySecrets(secret: linked ? Data(0..<16) : nil)
    self.secrets = secrets
    let notes = Notes()
    self.notes = notes
    switcher = Switcher(
      bonds: bonds, peers: peers, secrets: secrets, settings: settings, notify: { notes.items.append($0) })
    switcher.start()
    activitySubscription = switcher.$activity.sink { [unowned self] in activities.append($0) }
  }

  func peerSends(_ kind: LinkMessage.Kind, about address: String = trackpad.address) async -> Bool {
    let message = LinkMessage(kind: kind, address: Data(address.utf8))!
    return await peers.onMessage?(message) ?? false
  }
}

final class SwitcherProgressTests: XCTestCase {
  @MainActor func testTakeShowsEachStep() async {
    let h = Harness(holding: false, peer: .delivered)
    await h.switcher.take()
    XCTAssertEqual(
      h.activities,
      [.idle, .working("Asking your other Mac to release Trackpad…"), .working("Connecting Trackpad…"), .idle])
  }

  @MainActor func testTakeWithoutLinkSkipsAsking() async {
    let h = Harness(holding: false, peer: .noPeer, linked: false)
    await h.switcher.take()
    XCTAssertEqual(h.activities, [.idle, .working("Connecting Trackpad…"), .idle])
  }

  @MainActor func testSendShowsEachStep() async {
    let h = Harness(holding: true, peer: .delivered)
    await h.switcher.send()
    XCTAssertEqual(h.activities, [.idle, .working("Asking your other Mac to take Trackpad…"), .idle])
  }
}

final class SwitcherTakeTests: XCTestCase {
  @MainActor func testAsksPeerToReleaseThenAcquires() async {
    let h = Harness(holding: false, peer: .delivered)
    await h.switcher.take()
    XCTAssertEqual(h.peers.sentKinds, [.release])
    XCTAssertEqual(h.bonds.calls, ["acquire dev001"])
    XCTAssertTrue(h.switcher.holdsDevice)
    XCTAssertEqual(h.switcher.activity, .idle)
  }

  @MainActor func testPairsEvenWhenNoPeerAnswers() async {
    let h = Harness(holding: false, peer: .noPeer)
    await h.switcher.take()
    XCTAssertEqual(h.bonds.calls, ["acquire dev001"])
    XCTAssertTrue(h.switcher.holdsDevice)
  }

  @MainActor func testStopsWhenPeerRejects() async {
    let h = Harness(holding: false, peer: .rejected)
    await h.switcher.take()
    XCTAssertEqual(h.bonds.calls, [])
    XCTAssertEqual(h.switcher.activity, .failed(Switcher.rejectedMessage))
    XCTAssertEqual(h.notifications, [Switcher.rejectedMessage])
  }

  @MainActor func testDoesNothingWhenAlreadyHolding() async {
    let h = Harness(holding: true, peer: .delivered)
    await h.switcher.take()
    XCTAssertEqual(h.peers.sentKinds, [])
    XCTAssertEqual(h.bonds.calls, [])
  }

  @MainActor func testReportsFailedPairing() async {
    let h = Harness(holding: false, peer: .noPeer, acquireSucceeds: false)
    await h.switcher.take()
    XCTAssertFalse(h.switcher.holdsDevice)
    XCTAssertEqual(h.notifications.count, 1)
  }
}

final class SwitcherSendTests: XCTestCase {
  @MainActor func testReleasesOnlyAfterPeerConfirms() async {
    let h = Harness(holding: true, peer: .delivered)
    await h.switcher.send()
    XCTAssertEqual(h.peers.sentKinds, [.take])
    XCTAssertEqual(h.bonds.calls, ["release dev001"])
    XCTAssertFalse(h.switcher.holdsDevice)
  }

  @MainActor func testKeepsDeviceWithoutConfirmation() async {
    for outcome in [PeerOutcome.noPeer, .rejected, .failed] {
      let h = Harness(holding: true, peer: outcome)
      await h.switcher.send()
      XCTAssertEqual(h.bonds.calls, [], "\(outcome)")
      XCTAssertTrue(h.switcher.holdsDevice, "\(outcome)")
      XCTAssertEqual(h.notifications.count, 1, "\(outcome)")
    }
  }

  @MainActor func testRequiresLink() async {
    let h = Harness(holding: true, peer: .delivered, linked: false)
    await h.switcher.send()
    XCTAssertEqual(h.peers.sentKinds, [])
    XCTAssertTrue(h.switcher.holdsDevice)
  }
}

final class SwitcherPeerRequestTests: XCTestCase {
  @MainActor func testReleaseRequestReleases() async {
    let h = Harness(holding: true, peer: .noPeer)
    let acknowledged = await h.peerSends(.release)
    XCTAssertTrue(acknowledged)
    XCTAssertEqual(h.bonds.calls, ["release dev001"])
    XCTAssertFalse(h.switcher.holdsDevice)
  }

  @MainActor func testTakeRequestAcknowledgesBeforePairing() async {
    let h = Harness(holding: false, peer: .noPeer)
    let acknowledged = await h.peerSends(.take)
    XCTAssertTrue(acknowledged)
    let deadline = Date().addingTimeInterval(2)
    while !h.switcher.holdsDevice, Date() < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(h.bonds.calls, ["acquire dev001"])
    XCTAssertTrue(h.switcher.holdsDevice)
  }

  @MainActor func testTakeRequestKeepsReceivingStatus() async {
    let h = Harness(holding: false, peer: .noPeer)
    _ = await h.peerSends(.take)
    let deadline = Date().addingTimeInterval(2)
    while h.switcher.isBusy, Date() < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(h.activities, [.idle, .working("Receiving Trackpad…"), .idle])
  }

  @MainActor func testRefusesRequestsAboutOtherDevices() async {
    let h = Harness(holding: true, peer: .noPeer)
    let released = await h.peerSends(.release, about: "dev002")
    let taken = await h.peerSends(.take, about: "dev002")
    XCTAssertFalse(released)
    XCTAssertFalse(taken)
    XCTAssertEqual(h.bonds.calls, [])
    XCTAssertEqual(h.switcher.activity, .idle)
  }

  @MainActor func testRefusesRequestsWithoutChosenDevice() async {
    let h = Harness(holding: false, peer: .noPeer, device: nil)
    let released = await h.peerSends(.release)
    let taken = await h.peerSends(.take)
    XCTAssertFalse(released)
    XCTAssertFalse(taken)
    XCTAssertEqual(h.bonds.calls, [])
  }
}

final class SwitcherURLTests: XCTestCase {
  @MainActor func testSchemeAndHostIgnoreCase() async {
    let h = Harness(holding: false, peer: .delivered)
    h.switcher.handle(URL(string: "TrackpadSwitch://Take")!)
    let deadline = Date().addingTimeInterval(2)
    while !h.switcher.holdsDevice, Date() < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(h.bonds.calls, ["acquire dev001"])
  }

  @MainActor func testIgnoresOtherSchemes() async {
    let h = Harness(holding: false, peer: .delivered)
    h.switcher.handle(URL(string: "other://take")!)
    try? await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(h.bonds.calls, [])
  }
}

final class SwitcherSleepTests: XCTestCase {
  @MainActor func testHandsOffWhenPeerConfirms() {
    let h = Harness(holding: true, peer: .delivered)
    h.switcher.handOffBeforeSleep()
    XCTAssertEqual(h.peers.sentKinds, [.take])
    XCTAssertEqual(h.bonds.calls, ["release dev001"])
  }

  @MainActor func testKeepsDeviceWithoutConfirmation() {
    for outcome in [PeerOutcome.noPeer, .rejected, .failed] {
      let h = Harness(holding: true, peer: outcome)
      h.switcher.handOffBeforeSleep()
      XCTAssertEqual(h.bonds.calls, [], "\(outcome)")
    }
  }

  @MainActor func testSkipsWhenDisabled() {
    let h = Harness(holding: true, peer: .delivered)
    h.switcher.handOffOnSleep = false
    h.switcher.handOffBeforeSleep()
    XCTAssertEqual(h.peers.sentKinds, [])
  }
}

final class SwitcherLinkTests: XCTestCase {
  let otherMouse = ManagedDevice(address: "dev002", name: "Mouse")

  func made(secret: Data = Data(repeating: 9, count: 16), device: ManagedDevice?) -> LinkPairing.Link {
    LinkPairing.Link(secret: secret, peer: LinkPairing.PeerInfo(macName: "Studio", device: device))
  }

  @MainActor func testLinkStoresSecretAndPeerName() {
    let h = Harness(holding: false, peer: .noPeer, linked: false)
    XCTAssertTrue(h.switcher.link(made(device: nil)))
    XCTAssertTrue(h.switcher.isLinked)
    XCTAssertEqual(h.switcher.peerName, "Studio")
    XCTAssertEqual(h.settings.peerName, "Studio")
    XCTAssertEqual(h.secrets.stored, Data(repeating: 9, count: 16))
  }

  @MainActor func testRejectsSecretOfWrongLength() {
    let h = Harness(holding: false, peer: .noPeer, linked: false)
    XCTAssertFalse(h.switcher.link(made(secret: Data(count: 8), device: nil)))
    XCTAssertFalse(h.switcher.isLinked)
    XCTAssertNil(h.secrets.stored)
  }

  @MainActor func testAdoptsPeerDeviceWhenNoneChosen() {
    let h = Harness(holding: false, peer: .noPeer, linked: false, device: nil)
    h.switcher.link(made(device: trackpad))
    XCTAssertEqual(h.switcher.device, trackpad)
    XCTAssertEqual(h.settings.device, trackpad)
  }

  @MainActor func testKeepsOwnDevice() {
    let h = Harness(holding: false, peer: .noPeer, linked: false)
    h.switcher.link(made(device: otherMouse))
    XCTAssertEqual(h.switcher.device, trackpad)
  }

  @MainActor func testUnlinkForgetsSecretAndPeer() {
    let h = Harness(holding: false, peer: .noPeer)
    XCTAssertTrue(h.switcher.isLinked)
    h.switcher.unlink()
    XCTAssertFalse(h.switcher.isLinked)
    XCTAssertNil(h.switcher.peerName)
    XCTAssertNil(h.settings.peerName)
    XCTAssertNil(h.secrets.stored)
  }
}
