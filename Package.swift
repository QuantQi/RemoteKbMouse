// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RemoteKbMouse",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Host",
            path: "Sources/Host"
        ),
        .executableTarget(
            name: "Client",
            path: "Sources/Client"
        )
    ]
)
