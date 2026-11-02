import CoreBluetooth
import Foundation
import TrackpadSwitchCore
import os

/// Carries `LinkPairing` messages over a temporary GATT service while both Macs are linking. Both Macs
/// advertise and scan; when both start as initiator, the Mac whose first message sorts higher keeps that role.
/// The responder answers through `outbox`, announced on `signal`, because a notification carries at most ATT_MTU-3
/// bytes (Bluetooth Core Specification v5.4, Vol 3, Part F, 3.4.7.1).
final class PairingLink: NSObject, ObservableObject {
  enum Phase: Equatable {
    case idle
    case searching
    case comparing(String)
    case waiting
    case linked(String)
    case failed(String)
  }

  static let window: TimeInterval = 120
  static let lingerAfterLink: TimeInterval = 10

  private static let service = CBUUID(string: "F8CD694A-0AA4-4CFB-9BEE-FBB5CD656F73")
  private static let inbox = CBUUID(string: "FC8FB564-E7F4-43FA-882D-3060DCF60F39")
  private static let outbox = CBUUID(string: "E5A6E527-1C62-4B6C-8A51-60188E163696")
  private static let signal = CBUUID(string: "51DED500-7E9A-4358-8978-F8B6C1DEFCDC")

  @Published private(set) var phase = Phase.idle
  var onLinked: ((LinkPairing.Link) -> Bool)?

  private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "trackpadswitch", category: "pairing")
  private var info: LinkPairing.PeerInfo?
  private var pairing: LinkPairing?
  private var opening: Data?
  private var deadline: DispatchWorkItem?

  private var centralManager: CBCentralManager?
  private var peer: CBPeripheral?
  private var peerInbox: CBCharacteristic?
  private var peerOutbox: CBCharacteristic?

  private var peripheralManager: CBPeripheralManager?
  private var signalCharacteristic: CBMutableCharacteristic?
  private var outgoing = Data()
  private var sequence: UInt8 = 0
  private var signalPending = false

  var isActive: Bool {
    switch phase {
    case .searching, .comparing, .waiting: return true
    case .idle, .linked, .failed: return false
    }
  }

  func start(info: LinkPairing.PeerInfo) {
    stop()
    let pairing = LinkPairing(role: .initiator, info: info)
    guard let opening = try? pairing.start() else { return fail("Couldn't start linking. Try again.") }
    self.info = info
    self.pairing = pairing
    self.opening = opening
    phase = .searching
    log.notice("searching")
    peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
    centralManager = CBCentralManager(delegate: self, queue: nil)
    let deadline = DispatchWorkItem { [weak self] in
      guard let self, self.phase == .searching else { return }
      self.fail("Your other Mac wasn't found. Open TrackpadSwitch Settings on it and click Link a Mac, then try again.")
    }
    self.deadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.window, execute: deadline)
  }

  func confirm() {
    guard case .comparing = phase, let pairing else { return }
    phase = .waiting
    do {
      handle(try pairing.confirm())
    } catch {
      fail("Linking failed. Try again on both Macs.")
    }
  }

  func cancel() {
    stop()
    phase = .idle
  }

  func reject() {
    stop()
    phase = .failed("The numbers didn't match, so the Macs weren't linked. Try again on both Macs.")
  }

  private func handle(_ outputs: [LinkPairing.Output]) {
    for output in outputs {
      switch output {
      case .send(let message):
        deliver(message)
      case .compare(let digits):
        phase = .comparing(digits)
      case .linked(let link):
        guard onLinked?(link) == true else { return fail("Couldn't save the link. Try again on both Macs.") }
        log.notice("linked")
        phase = .linked(link.peer.macName)
        finishAfterLink()
      }
    }
  }

  private func deliver(_ message: Data) {
    if pairing?.role == .initiator {
      guard let peer, let peerInbox else { return fail("Lost the connection to your other Mac. Try again.") }
      peer.writeValue(message, for: peerInbox, type: .withResponse)
    } else {
      outgoing = message
      announce()
    }
  }

  private func announce() {
    sequence &+= 1
    sendSignal()
  }

  private func sendSignal() {
    guard let peripheralManager, let signalCharacteristic else { return }
    signalPending = !peripheralManager.updateValue(
      Data([sequence]), for: signalCharacteristic, onSubscribedCentrals: nil)
  }

  private func finishAfterLink() {
    deadline?.cancel()
    guard pairing?.role == .responder else { return stop() }
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.lingerAfterLink) { [weak self] in
      guard let self, case .linked = self.phase else { return }
      self.stop()
    }
  }

  private func fail(_ message: String) {
    let message =
      phase == .waiting && pairing?.role == .initiator
      ? "Linking didn't finish. If your other Mac shows it's linked, unlink it there, then try again on both Macs."
      : message
    log.error("\(message, privacy: .public)")
    stop()
    phase = .failed(message)
  }

  private func stop() {
    deadline?.cancel()
    deadline = nil
    centralManager?.stopScan()
    dropPeer()
    peripheralManager?.stopAdvertising()
    peripheralManager?.removeAllServices()
    centralManager = nil
    peripheralManager = nil
    signalCharacteristic = nil
    pairing = nil
    opening = nil
    outgoing = Data()
    signalPending = false
  }

  private func dropPeer() {
    if let peer {
      peer.delegate = nil
      centralManager?.cancelPeripheralConnection(peer)
    }
    peer = nil
    peerInbox = nil
    peerOutbox = nil
  }

  private func outranks(_ incoming: Data) -> Bool {
    guard phase == .searching, let opening, LinkPairing.isOpening(incoming) else { return false }
    return opening.lexicographicallyPrecedes(incoming)
  }

  private func becomeResponder() {
    guard let info else { return }
    log.notice("answering the other Mac")
    centralManager?.stopScan()
    dropPeer()
    opening = nil
    pairing = LinkPairing(role: .responder, info: info)
  }
}

extension PairingLink: CBPeripheralManagerDelegate {
  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    switch peripheral.state {
    case .poweredOn:
      let inbox = CBMutableCharacteristic(type: Self.inbox, properties: [.write], value: nil, permissions: [.writeable])
      let outbox = CBMutableCharacteristic(type: Self.outbox, properties: [.read], value: nil, permissions: [.readable])
      let signal = CBMutableCharacteristic(type: Self.signal, properties: [.notify], value: nil, permissions: [])
      signalCharacteristic = signal
      let service = CBMutableService(type: Self.service, primary: true)
      service.characteristics = [inbox, outbox, signal]
      peripheral.add(service)
    case .unauthorized:
      fail("TrackpadSwitch needs Bluetooth access. Allow it in System Settings › Privacy & Security › Bluetooth.")
    case .poweredOff:
      fail("Turn on Bluetooth to link your Macs.")
    default:
      break
    }
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
    guard error == nil else { return fail("Couldn't start linking. Try again.") }
    peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.service]])
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
    guard let first = requests.first else { return }
    let message = requests.sorted { $0.offset < $1.offset }.reduce(into: Data()) { $0.append($1.value ?? Data()) }
    if pairing?.role == .initiator {
      guard outranks(message) else {
        peripheral.respond(to: first, withResult: .writeNotPermitted)
        return
      }
      becomeResponder()
    }
    guard let pairing else {
      peripheral.respond(to: first, withResult: .unlikelyError)
      return
    }
    do {
      let outputs = try pairing.receive(message)
      peripheral.respond(to: first, withResult: .success)
      handle(outputs)
    } catch {
      peripheral.respond(to: first, withResult: .unlikelyError)
      fail("Linking failed. Try again on both Macs.")
    }
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
    guard request.characteristic.uuid == Self.outbox, request.offset <= outgoing.count else {
      peripheral.respond(to: request, withResult: .invalidOffset)
      return
    }
    request.value = outgoing.subdata(in: request.offset..<outgoing.count)
    peripheral.respond(to: request, withResult: .success)
  }

  func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
    guard signalPending else { return }
    sendSignal()
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic
  ) {
    guard pairing?.role == .responder else { return }
    if case .linked = phase {
      stop()
    } else if isActive {
      fail("Your other Mac stopped linking. Try again on both Macs.")
    }
  }
}

extension PairingLink: CBCentralManagerDelegate, CBPeripheralDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    guard central.state == .poweredOn, pairing?.role == .initiator else { return }
    central.scanForPeripherals(withServices: [Self.service])
  }

  func centralManager(
    _ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any],
    rssi: NSNumber
  ) {
    guard peer == nil, pairing?.role == .initiator, phase == .searching else { return }
    log.notice("found another Mac")
    central.stopScan()
    peer = peripheral
    peripheral.delegate = self
    central.connect(peripheral)
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard peripheral === peer else { return }
    peripheral.discoverServices([Self.service])
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    guard peripheral === peer else { return }
    fail("Couldn't connect to your other Mac. Try again.")
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    guard peripheral === peer, pairing?.role == .initiator, isActive else { return }
    fail("Lost the connection to your other Mac. Try again.")
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard peripheral === peer else { return }
    guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
      return fail("Couldn't connect to your other Mac. Try again.")
    }
    peripheral.discoverCharacteristics([Self.inbox, Self.outbox, Self.signal], for: service)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    guard peripheral === peer else { return }
    let characteristics = service.characteristics ?? []
    peerInbox = characteristics.first { $0.uuid == Self.inbox }
    peerOutbox = characteristics.first { $0.uuid == Self.outbox }
    guard peerInbox != nil, peerOutbox != nil, let signal = characteristics.first(where: { $0.uuid == Self.signal })
    else { return fail("Couldn't connect to your other Mac. Try again.") }
    peripheral.setNotifyValue(true, for: signal)
  }

  func peripheral(
    _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
  ) {
    guard peripheral === peer else { return }
    guard error == nil, characteristic.isNotifying, let opening else {
      return fail("Couldn't connect to your other Mac. Try again.")
    }
    deliver(opening)
  }

  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
    guard peripheral === peer, let error else { return }
    if (error as? CBATTError)?.code == .writeNotPermitted, phase == .searching {
      log.notice("the other Mac keeps the initiator role")
      return becomeResponder()
    }
    fail("Linking failed. Try again on both Macs.")
  }

  func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
    guard peripheral === peer, invalidatedServices.contains(where: { $0.uuid == Self.service }), isActive else {
      return
    }
    fail("Your other Mac stopped linking. Try again on both Macs.")
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    guard peripheral === peer else { return }
    guard error == nil else { return fail("Lost the connection to your other Mac. Try again.") }
    switch characteristic.uuid {
    case Self.signal:
      guard let peerOutbox else { return }
      peripheral.readValue(for: peerOutbox)
    case Self.outbox:
      guard let pairing, let message = characteristic.value else { return }
      do {
        handle(try pairing.receive(message))
      } catch {
        fail("Linking failed. Try again on both Macs.")
      }
    default:
      break
    }
  }
}
