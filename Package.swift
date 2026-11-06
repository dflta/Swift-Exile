// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftExile",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SwiftExile", targets: ["SwiftExile"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.5.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.2.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
    ],
    targets: [
        // All host logic lives here so it can be unit-tested headlessly.
        .target(
            name: "SwiftExileCore",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]
        ),
        // Thin AppKit shell: window, WKWebView, menus.
        .executableTarget(
            name: "SwiftExile",
            dependencies: ["SwiftExileCore"]
        ),
        .testTarget(
            name: "SwiftExileCoreTests",
            dependencies: [
                "SwiftExileCore",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ]
)
