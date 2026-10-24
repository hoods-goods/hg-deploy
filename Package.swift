// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "HGDeploy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HGDeployBuilder", targets: ["HGDeployBuilder"]),
        .library(name: "BuilderKit", targets: ["BuilderKit"]),
    ],
    targets: [
        // Everything that isn't UI: Apple's software catalog, drives, the files
        // HG Deploy puts on a drive. Unit tested.
        .target(name: "BuilderKit"),
        // The SwiftUI Builder app.
        .executableTarget(name: "HGDeployBuilder", dependencies: ["BuilderKit"]),
        .testTarget(
            name: "BuilderKitTests",
            dependencies: ["BuilderKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
