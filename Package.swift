// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "SquirrelPanel",
  platforms: [.macOS(.v13)],
  dependencies: [
    .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.6")
  ],
  targets: [
    .executableTarget(
      name: "SquirrelPanel",
      dependencies: ["Yams"],
      path: "Sources/SquirrelPanel"
    )
  ]
)
