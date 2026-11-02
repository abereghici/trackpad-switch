import Foundation
import IOKit
import IOKit.pwr_mgt

/// Sleep waits until `IOAllowPowerChange` acknowledges it, up to 30 s (Apple Technical Q&A QA1340).
final class SleepMonitor {
  // iokit_common_msg(0x270) and (0x280) in xnu iokit/IOKit/IOMessage.h; Swift does not import the macro.
  private static let canSystemSleep: UInt32 = 0xE000_0270
  private static let systemWillSleep: UInt32 = 0xE000_0280

  var onWillSleep: (() -> Void)?

  private var rootPort: io_connect_t = 0
  private var notifier: io_object_t = 0
  private var notifyPort: IONotificationPortRef?

  func start() {
    guard rootPort == 0 else { return }
    let context = Unmanaged.passUnretained(self).toOpaque()
    rootPort = IORegisterForSystemPower(
      context, &notifyPort,
      { context, _, type, argument in
        guard let context else { return }
        Unmanaged<SleepMonitor>.fromOpaque(context).takeUnretainedValue().handle(type, argument)
      }, &notifier)
    guard rootPort != 0, let notifyPort else { return }
    CFRunLoopAddSource(
      CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(), .commonModes)
  }

  private func handle(_ type: UInt32, _ argument: UnsafeMutableRawPointer?) {
    switch type {
    case Self.systemWillSleep:
      onWillSleep?()
      IOAllowPowerChange(rootPort, Int(bitPattern: argument))
    case Self.canSystemSleep:
      IOAllowPowerChange(rootPort, Int(bitPattern: argument))
    default:
      break
    }
  }
}
