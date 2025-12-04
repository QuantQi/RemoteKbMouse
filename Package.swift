// swift-tools-version:5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "RemoteKVM",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "Server", targets: ["Server"]),
        .executable(name: "Client", targets: ["Client"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "SharedCode",
            dependencies: []),
        .executableTarget(
            name: "Server",
            dependencies: ["SharedCode"]),
        .executableTarget(
            name: "Client",
            dependencies: ["SharedCode"],
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
