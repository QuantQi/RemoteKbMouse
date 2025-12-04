// swift-tools-version:5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "RemoteKVM",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Server", targets: ["Server"]),
        .executable(name: "Client", targets: ["Client"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.63.0")
    ],
    targets: [
        .target(
            name: "SharedCode",
            dependencies: []),
        .executableTarget(
            name: "Server",
            dependencies: ["SharedCode"]),
        .executableTarget(
            name: "Client",
            dependencies: [
                "SharedCode",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio")
            ],
            exclude: ["Info.plist"], // Exclude Info.plist from sources
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Client/Info.plist"
                ])
            ]
        ),
    ]
)
