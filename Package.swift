// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OrgScreenSaver",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "OrgScreenSaver", targets: ["OrgScreenSaver"])
    ],
    targets: [
        // Pure logic: no UI, fully unit-testable.
        .target(name: "OrgScreenSaverCore"),
        .executableTarget(name: "OrgScreenSaver", dependencies: ["OrgScreenSaverCore"]),
        .testTarget(name: "OrgScreenSaverCoreTests", dependencies: ["OrgScreenSaverCore"])
    ]
)
