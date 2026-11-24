// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RemoteCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "RemoteCore", targets: ["RemoteCore"]),
    ],
    dependencies: [
        // Apple 環境では CryptoKit を使う。Linux（テスト用）では同じ API の swift-crypto を使う。
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"),
    ],
    targets: [
        .target(
            name: "RemoteCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ]
        ),
        .testTarget(
            name: "RemoteCoreTests",
            dependencies: ["RemoteCore"]
        ),
    ]
)
