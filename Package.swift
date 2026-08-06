// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwitchrCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SwitchrCore",
            targets: ["SwitchrCore"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/ordo-one/FuzzyMatch", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "SwitchrCore",
            dependencies: [
                .product(name: "FuzzyMatch", package: "FuzzyMatch")
            ]
        ),
        .testTarget(
            name: "SwitchrCoreTests",
            dependencies: ["SwitchrCore"]
        )
    ]
)
