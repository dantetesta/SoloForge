// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "GuitarWorkbench",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "MusicCore"),
        .executableTarget(name: "Workbench", dependencies: ["MusicCore", "CSQLite"]),
        .testTarget(name: "MusicCoreTests", dependencies: ["MusicCore"]),
        .testTarget(name: "WorkbenchTests", dependencies: ["Workbench"])
    ]
)
