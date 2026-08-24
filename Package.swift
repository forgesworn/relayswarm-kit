// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RelaySwarmKit",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "RelaySwarmSignalling", targets: ["RelaySwarmSignalling"]),
        // Rendezvous plus the pipe: WebRTC data channels over libdatachannel,
        // with a host that answers viewers' encrypted offers. The binary
        // slice is macos-arm64 today; the signalling product runs everywhere.
        .library(name: "RelaySwarmTransport", targets: ["RelaySwarmTransport"]),
        .library(name: "RelaySwarmTestSupport", targets: ["RelaySwarmTestSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1.git", from: "0.18.0"),
    ],
    targets: [
        .target(name: "RelaySwarmSignalling",
                dependencies: [.product(name: "P256K", package: "swift-secp256k1")]),
        .binaryTarget(
            name: "CDataChannel",
            url: "https://github.com/forgesworn/relayswarm-kit/releases/download/v0.1.0/DataChannel.xcframework.zip",
            checksum: "a39448b7940c00cfb1a8ec550d2692412e85d48c12d443df1486dedd7ae2f5f3"),
        .target(name: "RelaySwarmTransport",
                dependencies: ["RelaySwarmSignalling", "CDataChannel"],
                linkerSettings: [.linkedLibrary("c++")]),
        // The in-process relay the suites run against, published so
        // consumers can test their own integrations the same way.
        .target(name: "RelaySwarmTestSupport", dependencies: ["RelaySwarmSignalling"]),
        .testTarget(name: "RelaySwarmSignallingTests",
                    dependencies: ["RelaySwarmSignalling", "RelaySwarmTestSupport"]),
        .testTarget(name: "RelaySwarmTransportTests",
                    dependencies: ["RelaySwarmTransport", "RelaySwarmTestSupport"]),
    ]
)
