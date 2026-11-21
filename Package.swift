// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacAppMCPKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MacAppMCPKit", targets: ["MacAppMCPKit"]),
        /// For the small tool an app embeds so Claude Desktop (and other assistants that start programs) can connect.
        .library(name: "MacAppMCPBridge", targets: ["MacAppMCPBridge"]),
    ],
    targets: [
        .target(name: "MacAppMCPKit"),
        .target(name: "MacAppMCPBridge"),
    ]
)
