// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AgentNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AgentNotch",
            path: "Sources/AgentNotch"
        )
    ]
)
