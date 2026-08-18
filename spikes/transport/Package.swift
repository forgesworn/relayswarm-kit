// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Transport spike: libdatachannel driven from Swift, and the full remote
// watch journey against a real browser. Build libdatachannel first (see
// README.md here), then point LIBDATACHANNEL_BUILD at its build directory.
let environment = ProcessInfo.processInfo.environment
let libdir = environment["LIBDATACHANNEL_BUILD"] ?? "../../../libdatachannel/build"
let openssl = environment["OPENSSL_LIB"] ?? "/opt/homebrew/opt/openssl@3/lib"

let link: [LinkerSetting] = [
    .unsafeFlags([
        "-L", libdir,
        "-L", "\(libdir)/deps/libjuice",
        "-L", "\(libdir)/deps/usrsctp/usrsctplib",
        "-L", openssl,
        "-ldatachannel", "-ljuice", "-lusrsctp",
        "-lssl", "-lcrypto", "-lc++",
    ]),
]

let package = Package(
    name: "transport-spike",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .target(name: "CRTC"),
        .executableTarget(name: "dcspike", dependencies: ["CRTC"], linkerSettings: link),
        // watchspike rides the shipping transport product, prebuilt libs
        // included - it needs no local libdatachannel build at all.
        .executableTarget(
            name: "watchspike",
            dependencies: [
                .product(name: "RelaySwarmSignalling", package: "relayswarmkit"),
                .product(name: "RelaySwarmTransport", package: "relayswarmkit"),
            ]),
    ]
)
