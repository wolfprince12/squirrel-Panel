// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "SquirrelPanel",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.6")
  ],
  targets: [
    .executableTarget(
      name: "SquirrelPanel",
      dependencies: ["Yams", "SP-AIEnergyAgent"],
      path: "Sources/SquirrelPanel"
    ),
    .executableTarget(
      name: "SP-AIEnergyAgent",
      path: "Sources/SP-AIEnergyAgent"
    ),
    .testTarget(
      name: "SquirrelPanelTests",
      dependencies: ["SquirrelPanel", "Yams"],
      path: "Tests/SquirrelPanelTests"
    )
  ]
)
