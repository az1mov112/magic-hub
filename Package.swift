// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MagicHub",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "MagicHub", targets: ["MagicHub"]),
        .library(name: "MediaRemoteBridge", type: .dynamic, targets: ["MediaRemoteBridge"])
    ],
    targets: [
        .executableTarget(
            name: "MagicHub",
            path: "Sources/MagicHub"
        ),
        // Загружается системным /usr/bin/perl (см. Resources/mediaremote.pl), а не самим приложением:
        // так macOS 15.4+ отдаёт сведения о том, что сейчас играет.
        .target(
            name: "MediaRemoteBridge",
            path: "Sources/MediaRemoteBridge",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("AppKit")]
        )
    ]
)
