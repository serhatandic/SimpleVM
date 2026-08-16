// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SimpleVMCore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SimpleVMCore", targets: ["SimpleVMCore"])
    ],
    targets: [
        .target(name: "SimpleVMCore"),
        .testTarget(
            name: "SimpleVMCoreTests",
            dependencies: ["SimpleVMCore"]
        )
    ]
)

