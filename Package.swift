// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RelaySwarmKit",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "RelaySwarmSignalling", targets: ["RelaySwarmSignalling"]),
    ],
    dependencies: [
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1.git", from: "0.18.0"),
    ],
    targets: [
        .target(name: "RelaySwarmSignalling",
                dependencies: [.product(name: "P256K", package: "swift-secp256k1")]),
        .testTarget(name: "RelaySwarmSignallingTests", dependencies: ["RelaySwarmSignalling"]),
    ]
)
