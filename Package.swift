// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "SquirrelPanel",
  defaultLocalization: "zh-Hans",
  platforms: [.macOS(.v13)],
  dependencies: [
    .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.6")
  ],
  targets: [
    .executableTarget(
      name: "SquirrelPanel",
      dependencies: ["Yams"],
      path: "Sources/SquirrelPanel",
      resources: [
        .process("Resources")
      ]
    ),
    .testTarget(
      name: "SquirrelPanelTests",
      dependencies: ["SquirrelPanel", "Yams"],
      path: "Tests/SquirrelPanelTests"
    )
  ]
)
