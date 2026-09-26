// swift-tools-version: 6.2
import PackageDescription
import Foundation

// The release build of the core, for every configuration: the manifest is not
// told which one it is building. Scripts/build_rust.sh builds only this one.
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
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("SystemConfiguration"),
                .unsafeFlags(["-L\(rustLibDir)", "-lreadout_core"])
            ]
        )
    ]
)
