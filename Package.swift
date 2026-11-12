// swift-tools-version: 5.9
import PackageDescription

let package = Package(name: "LTEWatch", platforms: [.macOS(.v14)], products: [
    .executable(name: "LTEWatch", targets: ["LTEWatch"])
], targets: [
    .executableTarget(name: "LTEWatch")
])
