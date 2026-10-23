// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "any_core_vpn",
    platforms: [
        .macOS("12.0") 
    ],
    products: [
        .library(
            name: "any-core-vpn",
            targets: ["any_core_vpn"]
        )
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "any_core_vpn",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                .copy("Resources/cores"),
                .process("PrivacyInfo.xcprivacy")
            ],

            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-ObjC"])
            ]
        )
    ]
)