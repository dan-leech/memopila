// swift-tools-version: 6.0
import PackageDescription

// macOS services for Memopila (PLAN §7.1): SwiftData store, pasteboard adapters, thumbnails,
// text recognition. Builds and tests on macOS only; the platform-independent logic stays in MemopilaCore.
let package = Package(
    name: "MemopilaServices",
    platforms: [.macOS("15.4")],
    products: [
        .library(name: "MemopilaServices", targets: ["MemopilaServices"]),
    ],
    dependencies: [
        .package(path: "../MemopilaCore"),
    ],
    targets: [
        // Narrow Objective-C boundary that turns NSException into an error (§3.2.1).
        .target(name: "MPLObjCSupport"),
        .target(
            name: "MemopilaServices",
            dependencies: [
                .product(name: "MemopilaCore", package: "MemopilaCore"),
                "MPLObjCSupport",
            ]
        ),
        .testTarget(
            name: "MemopilaServicesTests",
            dependencies: ["MemopilaServices"]
        ),
    ]
)
