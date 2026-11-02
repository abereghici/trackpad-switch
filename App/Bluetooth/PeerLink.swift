@preconcurrency import CoreBluetooth
import Foundation
import TrackpadSwitchCore
import os

final class PeerLink: NSObject, @unchecked Sendable {
  typealias Outcome = PeerOutcome

  static let scanWindow: TimeInterval = 2
  static let exchangeTimeout: TimeInterval = 8

  var onMessage: (@Sendable (LinkMessage) async -> Bool)?

  private let queue = DispatchQueue(label: "trackpadswitch.link")
  private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "trackpadswitch", category: "link")
  private var key: LinkKey?
  private var peripheralManager: CBPeripheralManager?
  private var centralManager: CBCentralManager?
  private var replayGuard = ReplayGuard()
  private var operation: SendOperation?

  func configure(key: LinkKey?) {
    queue.async {
      self.finishOperation(.failed)
      self.peripheralManager?.stopAdvertising()
      self.peripheralManager?.removeAllServices()
      self.peripheralManager = nil
      self.centralManager = nil
      self.replayGuard = ReplayGuard()
      self.key = key
      guard key != nil else { return }
      self.peripheralManager = CBPeripheralManager(delegate: self, queue: self.queue)
      self.centralManager = CBCentralManager(delegate: self, queue: self.queue)
    }
  }

  /// `address`: the 6 bytes of a `BluetoothDeviceAddress`.
  func send(_ kind: LinkMessage.Kind, address: Data) async -> Outcome {
    guard let message = LinkMessage(kind: kind, address: address) else { return .failed }
    return await withCheckedContinuation { continuation in
      queue.async {
        self.startOperation(message) { continuation.resume(returning: $0) }
      }
    }
  }

  // MARK: - Sending

  private final class SendOperation {
    let payload: Data
    let serviceUUID: CBUUID
    let characteristicUUID: CBUUID
    let completion: (Outcome) -> Void
    let started = ContinuousClock.now
    var scanning = true
    var inFlight: [UUID: CBPeripheral] = [:]
    var results: [Outcome] = []

    init(payload: Data, key: LinkKey, completion: @escaping (Outcome) -> Void) {
      self.payload = payload
      serviceUUID = CBUUID(data: key.serviceID)
      characteristicUUID = CBUUID(data: key.commandCharacteristicID)
      self.completion = completion
    }
  }

  private func startOperation(_ message: LinkMessage, completion: @escaping (Outcome) -> Void) {
    guard operation == nil, let key, let centralManager, centralManager.state == .poweredOn else {
      completion(operation == nil ? .noPeer : .failed)
      return
    }
    let operation = SendOperation(payload: message.encoded(with: key), key: key, completion: completion)
    self.operation = operation
    centralManager.scanForPeripherals(withServices: [operation.serviceUUID])
    queue.asyncAfter(deadline: .now() + Self.scanWindow) { [weak self, weak operation] in
      guard let self, let operation, self.operation === operation else { return }
      operation.scanning = false
      self.centralManager?.stopScan()
      self.finishIfSettled()
    }
    queue.asyncAfter(deadline: .now() + Self.scanWindow + Self.exchangeTimeout) { [weak self, weak operation] in
      guard let self, let operation, self.operation === operation else { return }
      self.finishOperation(operation.results.contains(.delivered) ? .delivered : .failed)
    }
  }

  private func exchangeEnded(_ peripheral: CBPeripheral, _ outcome: Outcome) {
    guard let operation, operation.inFlight.removeValue(forKey: peripheral.identifier) != nil else { return }
    operation.results.append(outcome)
    centralManager?.cancelPeripheralConnection(peripheral)
    finishIfSettled()
  }

  private func finishIfSettled() {
    guard let operation, operation.inFlight.isEmpty else { return }
    if operation.results.contains(.delivered) {
      finishOperation(.delivered)
    } else if !operation.scanning {
      finishOperation(operation.results.contains(.rejected) ? .rejected : operation.results.isEmpty ? .noPeer : .failed)
    }
  }

  private func finishOperation(_ outcome: Outcome) {
    guard let operation else { return }
    self.operation = nil
    log.notice(
      "exchange: \(String(describing: outcome), privacy: .public) from \(operation.results.count, privacy: .public) peers in \(operation.started.duration(to: .now), privacy: .public)"
    )
    centralManager?.stopScan()
    for peripheral in operation.inFlight.values {
      centralManager?.cancelPeripheralConnection(peripheral)
    }
    operation.completion(outcome)
  }

  // MARK: - Receiving

  private func publishService() {
    guard let key, let peripheralManager, peripheralManager.state == .poweredOn else { return }
    let characteristic = CBMutableCharacteristic(
      type: CBUUID(data: key.commandCharacteristicID),
      properties: [.write],
      value: nil,
      permissions: [.writeable])
    let service = CBMutableService(type: CBUUID(data: key.serviceID), primary: true)
    service.characteristics = [characteristic]
    peripheralManager.removeAllServices()
    peripheralManager.add(service)
  }

  private func handle(_ payload: Data) -> Result<LinkMessage, CBATTError> {
    guard let key else { return .failure(CBATTError(.unlikelyError)) }
    guard let message = try? LinkMessage.decode(payload, with: key) else {
      return .failure(CBATTError(.insufficientAuthorization))
    }
    guard replayGuard.check(message, now: UInt64(Date().timeIntervalSince1970)) == .accepted else {
      return .failure(CBATTError(.insufficientAuthorization))
    }
    return .success(message)
  }
}

extension PeerLink: CBPeripheralManagerDelegate {
  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    publishService()
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
    guard error == nil else { return }
    peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [service.uuid]])
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
    guard let first = requests.first else { return }
    let payload = requests.sorted { $0.offset < $1.offset }.reduce(into: Data()) { $0.append($1.value ?? Data()) }
    switch handle(payload) {
    case .failure(let error):
      peripheral.respond(to: first, withResult: error.code)
    case .success(let message):
      let handler = onMessage
      Task {
        let accepted = await handler?(message) ?? false
        self.queue.async {
          peripheral.respond(to: first, withResult: accepted ? .success : .unlikelyError)
        }
      }
    }
  }
}

extension PeerLink: CBCentralManagerDelegate, CBPeripheralDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    if central.state != .poweredOn {
      finishOperation(.failed)
    }
  }

  func centralManager(
    _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any], rssi: NSNumber
  ) {
    guard let operation, operation.inFlight[peripheral.identifier] == nil else { return }
    log.notice("found peer in \(operation.started.duration(to: .now), privacy: .public)")
    operation.inFlight[peripheral.identifier] = peripheral
    peripheral.delegate = self
    central.connect(peripheral)
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard let operation else { return }
    peripheral.discoverServices([operation.serviceUUID])
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    exchangeEnded(peripheral, .failed)
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    exchangeEnded(peripheral, .failed)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard let operation,
      let service = peripheral.services?.first(where: { $0.uuid == operation.serviceUUID })
    else {
      exchangeEnded(peripheral, .failed)
      return
    }
    peripheral.discoverCharacteristics([operation.characteristicUUID], for: service)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    guard let operation,
      let characteristic = service.characteristics?.first(where: { $0.uuid == operation.characteristicUUID })
    else {
      exchangeEnded(peripheral, .failed)
      return
    }
    peripheral.writeValue(operation.payload, for: characteristic, type: .withResponse)
  }

  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
    switch (error as? CBATTError)?.code {
    case nil where error == nil:
      exchangeEnded(peripheral, .delivered)
    case .insufficientAuthorization?:
      exchangeEnded(peripheral, .rejected)
    default:
      exchangeEnded(peripheral, .failed)
    }
  }
}

extension PeerLink: PeerMessaging {}
