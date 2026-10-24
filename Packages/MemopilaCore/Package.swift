// swift-tools-version: 6.0
import PackageDescription

// Platform-independent core of Memopila (PLAN §7.1): capture decisions, canonical hashing,
// format policy, retention planning and text tools. No AppKit, SwiftData or Vision here,
// so the whole package builds and tests on Linux as well as macOS.
let package = Package(
    name: "MemopilaCore",
    platforms: [.macOS("15.4")],
    products: [
        .library(name: "MemopilaCore", targets: ["MemopilaCore"]),
    ],
    dependencies: [
        // SHA-256 on Linux only; macOS uses CryptoKit.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"),
    ],
    targets: [
        .target(
            name: "MemopilaCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ]
        ),
        .testTarget(
            name: "MemopilaCoreTests",
            dependencies: ["MemopilaCore"]
        ),
    ]
)
