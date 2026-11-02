// swift-tools-version:6.2
import PackageDescription

let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
  name: "TrackpadSwitchCore",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "TrackpadSwitchCore", targets: ["TrackpadSwitchCore"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-crypto.git", "4.0.0"..<"6.0.0")
  ],
  targets: [
    .target(
      name: "TrackpadSwitchCore",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto"), .product(name: "CryptoExtras", package: "swift-crypto"),
      ],
      swiftSettings: strict),
    .testTarget(name: "TrackpadSwitchCoreTests", dependencies: ["TrackpadSwitchCore"], swiftSettings: strict),
  ],
  swiftLanguageModes: [.v5]
)
