// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Negs",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NegsApp", targets: ["NegsApp"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .systemLibrary(name: "CNegsCore", path: "Sources/CNegsCore"),
        .executableTarget(name: "NegsApp", dependencies: ["Sparkle", "CNegsCore"],
                          linkerSettings: [.linkedFramework("CoreML"), .linkedFramework("CoreImage"),
                                           .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "NegsTests", dependencies: ["NegsApp"])
    ]
)
