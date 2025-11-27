// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RemoteKbMouse",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "RemoteKbMouseHost", targets: ["RemoteKbMouseHost"]),
        .executable(name: "RemoteKbMouseClient", targets: ["RemoteKbMouseClient"]),
    ],
    targets: [
        // Shared library
        .target(
            name: "Shared",
            path: "Shared"
        ),
        // Host executable
        .executableTarget(
            name: "RemoteKbMouseHost",
            dependencies: ["Shared"],
            path: "RemoteKbMouseHost"
        ),
        // Client executable
        .executableTarget(
            name: "RemoteKbMouseClient",
            dependencies: ["Shared"],
            path: "RemoteKbMouseClient"
        ),
    ]
)
