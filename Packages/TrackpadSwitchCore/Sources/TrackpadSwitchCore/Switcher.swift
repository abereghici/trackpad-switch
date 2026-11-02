import Combine
import Foundation
import os

/// Safety rule: this Mac releases the device only after the other Mac accepted the request to take it.
@MainActor
public final class Switcher: ObservableObject {
  public enum Activity: Equatable {
    case idle
    case working(String)
    case failed(String)
  }

  /// Covers the peer link's worst case (2 s scan + 8 s exchange); macOS waits up to 30 s (Apple Technical Q&A QA1340).
  public static let sleepHandOffTimeout: TimeInterval = 12

  @Published public private(set) var activity: Activity = .idle
  @Published public private(set) var holdsDevice = false
  @Published public private(set) var isLinked = false
  @Published public private(set) var peerName: String?
  @Published public private(set) var device: ManagedDevice?
  @Published public var handOffOnSleep: Bool {
    didSet { settings.handOffOnSleep = handOffOnSleep }
  }

  private let bonds: any DeviceBonding
  private let peers: any PeerMessaging
  private let secrets: any SecretStore
  private let settings: SwitcherSettings
  private let notify: (String) -> Void
  private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "trackpadswitch", category: "switcher")

  public init(
    bonds: any DeviceBonding, peers: any PeerMessaging, secrets: any SecretStore,
    settings: SwitcherSettings, notify: @escaping (String) -> Void
  ) {
    self.bonds = bonds
    self.peers = peers
    self.secrets = secrets
    self.settings = settings
    self.notify = notify
    handOffOnSleep = settings.handOffOnSleep
    device = settings.device
    peerName = settings.peerName
  }

  public var isBusy: Bool {
    if case .working = activity { return true }
    return false
  }

  public func start() {
    peers.onMessage = { [weak self] message in
      await self?.receive(message) ?? false
    }
    applyLink(secrets.loadLinkSecret().flatMap(LinkKey.init(secret:)))
    refresh()
  }

  public func refresh() {
    holdsDevice = device.map { bonds.isConnected($0.address) } ?? false
  }

  // MARK: - Settings

  public func select(_ device: ManagedDevice) {
    self.device = device
    settings.device = device
    refresh()
  }

  /// Stores the link made by `LinkPairing`; takes the other Mac's device when this Mac has none yet.
  @discardableResult
  public func link(_ link: LinkPairing.Link) -> Bool {
    guard let key = LinkKey(secret: link.secret), secrets.saveLinkSecret(link.secret) else { return false }
    settings.peerName = link.peer.macName
    peerName = link.peer.macName
    if device == nil, let peerDevice = link.peer.device {
      select(peerDevice)
    }
    applyLink(key)
    return true
  }

  public func unlink() {
    secrets.deleteLinkSecret()
    settings.peerName = nil
    peerName = nil
    applyLink(nil)
  }

  private func applyLink(_ key: LinkKey?) {
    peers.configure(key: key)
    isLinked = key != nil
  }

  // MARK: - Switching

  public func handle(_ url: URL) {
    guard url.scheme?.lowercased() == "trackpadswitch" else { return }
    switch url.host?.lowercased() {
    case "take": Task { await take() }
    case "send": Task { await send() }
    case "toggle": Task { await toggle() }
    default: break
    }
  }

  public func toggle() async {
    refresh()
    if holdsDevice {
      await send()
    } else {
      await take()
    }
  }

  public func take() async {
    guard let device, !isBusy else { return }
    refresh()
    guard !holdsDevice else { return }
    if isLinked, let bytes = bonds.wireAddress(device.address) {
      activity = .working("Asking your other Mac to release \(device.name)…")
      let outcome = await timed("release request") { await peers.send(.release, address: bytes) }
      if outcome == .rejected {
        return fail(Self.rejectedMessage)
      }
      activity = .working("Connecting \(device.name)…")
    }
    await acquire(device)
  }

  public func send() async {
    guard let device, !isBusy else { return }
    refresh()
    guard holdsDevice else { return }
    guard isLinked else { return fail("Link your other Mac in Settings first.") }
    guard let bytes = bonds.wireAddress(device.address) else { return fail("Choose the device again in Settings.") }
    activity = .working("Asking your other Mac to take \(device.name)…")
    let outcome = await timed("take request") { await peers.send(.take, address: bytes) }
    switch outcome {
    case .delivered:
      _ = await timed("release") { await bonds.release(device.address) }
      finish()
    case .noPeer:
      fail("Your other Mac didn't answer. Make sure it's awake, nearby and running TrackpadSwitch.")
    case .rejected:
      fail(Self.rejectedMessage)
    case .failed:
      fail("Couldn't reach your other Mac. Try again.")
    }
  }

  private func acquire(_ device: ManagedDevice) async {
    if !isBusy { activity = .working("Connecting \(device.name)…") }
    let connected = await timed("acquire") { await bonds.acquire(device.address) }
    if connected {
      finish()
    } else {
      fail("Couldn't connect \(device.name). If it keeps failing, switch it off and on, then try again.")
    }
  }

  private func timed<T>(_ step: String, _ work: () async -> T) async -> T {
    let start = ContinuousClock.now
    let result = await work()
    log.notice(
      "\(step, privacy: .public): \(String(describing: result), privacy: .public) in \(start.duration(to: .now), privacy: .public)"
    )
    return result
  }

  private func finish() {
    activity = .idle
    refresh()
  }

  private func fail(_ message: String) {
    log.error("\(message, privacy: .private)")
    activity = .failed(message)
    refresh()
    notify(message)
  }

  static let rejectedMessage =
    "Your other Mac rejected the request. Make sure both Macs set the date and time automatically."

  // MARK: - Peer requests

  func receive(_ message: LinkMessage) async -> Bool {
    guard let device, bonds.address(fromWire: message.address) == device.address else {
      log.error("peer asked about a device this Mac doesn't manage")
      return false
    }
    log.notice("peer asked: \(String(describing: message.kind), privacy: .public)")
    switch message.kind {
    case .release:
      let released = await timed("release") { await bonds.release(device.address) }
      refresh()
      return released
    case .take:
      guard !isBusy else { return false }
      activity = .working("Receiving \(device.name)…")
      Task { await acquire(device) }
      return true
    }
  }

  // MARK: - Sleep

  /// Blocks the caller until the hand-off finishes or the timeout passes; call it from the sleep notification.
  public func handOffBeforeSleep() {
    guard handOffOnSleep, isLinked, let address = device?.address, bonds.isConnected(address),
      let bytes = bonds.wireAddress(address)
    else { return }
    let bonds = self.bonds
    let peers = self.peers
    let done = DispatchSemaphore(value: 0)
    Task.detached {
      if await peers.send(.take, address: bytes) == .delivered {
        _ = await bonds.release(address)
      }
      done.signal()
    }
    _ = done.wait(timeout: .now() + Self.sleepHandOffTimeout)
  }
}
