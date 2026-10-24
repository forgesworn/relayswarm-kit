// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RelaySwarmKit",
    platforms: [.macOS(.v14), .iOS(.v16)],
    products: [
        .library(name: "RelaySwarmSignalling", targets: ["RelaySwarmSignalling"]),
        .library(name: "RelaySwarmMedia", targets: ["RelaySwarmMedia"]),
        .library(name: "RelaySwarmCore", targets: ["RelaySwarmCore"]),
        .executable(name: "relayswarm-interop", targets: ["RelaySwarmInteropFixture"]),
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
        .binaryTarget(name: "relayswarm_ffiFFI",
            url: "https://github.com/forgesworn/relayswarm/releases/download/v0.3.0/relayswarm-core.xcframework.zip",
            checksum: "bc57bcf2b7566bc675af816f9e63c64332354d3cebdb43eb7b2d723d84498f2c"),
        .target(name: "RelaySwarmCore", dependencies: ["relayswarm_ffiFFI"]),
        .target(name: "RelaySwarmMedia", dependencies: ["RelaySwarmSignalling", "RelaySwarmCore"]),
        .binaryTarget(
            name: "CDataChannel",
            // The checked-in archive, not a release download. The v0.1.0
            // asset is the older build, 113 of whose objects want macOS
            // 14.6, so consuming it by URL would reinstate the deployment
            // target this package declares it does not need. Cutting a
            // release from build/DataChannel.xcframework.zip is what would
            // let this go back to url/checksum.
            path: "build/DataChannel.xcframework"),
        .target(name: "RelaySwarmTransport",
                dependencies: ["RelaySwarmSignalling", "RelaySwarmMedia", "RelaySwarmCore", "CDataChannel"],
                linkerSettings: [.linkedLibrary("c++")]),
        // The in-process relay the suites run against, published so
        // consumers can test their own integrations the same way.
        .target(name: "RelaySwarmTestSupport", dependencies: ["RelaySwarmSignalling"]),
        .testTarget(name: "RelaySwarmSignallingTests",
                    dependencies: ["RelaySwarmSignalling", "RelaySwarmTestSupport"]),
        .executableTarget(name: "RelaySwarmInteropFixture", dependencies: ["RelaySwarmSignalling", "RelaySwarmTransport", "RelaySwarmMedia"], path: "Tests/Interop"),
        .testTarget(name: "RelaySwarmMediaTests", dependencies: ["RelaySwarmMedia", "RelaySwarmSignalling", "RelaySwarmCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "RelaySwarmTransportTests",
                    dependencies: ["RelaySwarmTransport", "RelaySwarmTestSupport", "RelaySwarmMedia"]),
    ]
)
