import Foundation

public struct ReplayGuard: Sendable {
  public enum Verdict: Equatable, Sendable {
    case accepted, stale, replayed
  }

  public let window: UInt64
  private var seen: [UInt64: UInt64] = [:]

  public init(window: UInt64 = 30) {
    self.window = window
  }

  public mutating func check(_ message: LinkMessage, now: UInt64) -> Verdict {
    let skew = now > message.timestamp ? now - message.timestamp : message.timestamp - now
    guard skew <= window else { return .stale }
    seen = seen.filter { $0.value + window >= now }
    guard seen[message.nonce] == nil else { return .replayed }
    seen[message.nonce] = message.timestamp
    return .accepted
  }

  var trackedCount: Int { seen.count }
}
