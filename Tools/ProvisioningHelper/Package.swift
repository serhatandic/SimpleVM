// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SimpleVMProvisioningHelper",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(
            url: "https://github.com/apple/containerization.git",
            revision: "5427fd21ded4b84034126caef5b3182900b4776d"
        ),
        .package(
            url: "https://github.com/apple/swift-system.git",
            from: "1.6.4"
        )
    ],
    targets: [
        .executableTarget(
            name: "SimpleVMProvisioningHelper",
            dependencies: [
                .product(
                    name: "ContainerizationArchive",
                    package: "containerization"
                ),
                .product(
                    name: "ContainerizationEXT4",
                    package: "containerization"
                ),
                .product(
                    name: "ContainerizationOCI",
                    package: "containerization"
                ),
                .product(name: "SystemPackage", package: "swift-system")
            ]
        )
    ]
)
