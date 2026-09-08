// swift-tools-version: 6.2
import PackageDescription
import Foundation

let rustLibDir = "\(Context.packageDirectory)/core/target/aarch64-apple-darwin/release"

let package = Package(
    name: "Readout",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CReadoutCore",
            path: "Sources/CReadoutCore",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "Readout",
            dependencies: ["CReadoutCore"],
            path: "Sources/Readout",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("SystemConfiguration"),
                .unsafeFlags(["-L\(rustLibDir)", "-lreadout_core"])
            ]
        )
    ]
)
