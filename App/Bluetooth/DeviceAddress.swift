import Foundation
import IOBluetooth

enum DeviceAddress {
  static func device(_ address: String) -> IOBluetoothDevice? {
    guard var raw = parse(address) else { return nil }
    return IOBluetoothDevice(address: &raw)
  }

  static func bytes(_ address: String) -> Data? {
    guard let raw = parse(address) else { return nil }
    return withUnsafeBytes(of: raw) { Data($0) }
  }

  static func string(_ bytes: Data) -> String? {
    var raw = BluetoothDeviceAddress()
    guard bytes.count == MemoryLayout.size(ofValue: raw) else { return nil }
    withUnsafeMutableBytes(of: &raw) { $0.copyBytes(from: bytes) }
    return IOBluetoothNSStringFromDeviceAddress(&raw)
  }

  private static func parse(_ address: String) -> BluetoothDeviceAddress? {
    var raw = BluetoothDeviceAddress()
    return IOBluetoothNSStringToDeviceAddress(address, &raw) == kIOReturnSuccess ? raw : nil
  }
}
