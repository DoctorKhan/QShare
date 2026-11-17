// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuickShareKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "QuickShareKit", targets: ["QuickShareKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
    ],
    targets: [
        .target(
            name: "QuickShareKit",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        .testTarget(name: "QuickShareKitTests", dependencies: ["QuickShareKit"]),
    ]
)
