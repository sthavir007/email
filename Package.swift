// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "email",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "email", path: "Sources/email")
    ]
)
