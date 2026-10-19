// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Wavedrop",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "Wavedrop",
            path: "Sources/Wavedrop",
            swiftSettings: [.unsafeFlags(["-Ounchecked"])]
        )
    ],
    swiftLanguageModes: [.v5]
)
