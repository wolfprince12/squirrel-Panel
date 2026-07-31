import XCTest
@testable import SquirrelPanel

final class CustomYAMLFileTests: XCTestCase {
  func testRoundTrip() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appending(path: UUID().uuidString)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appending(path: "squirrel.custom.yaml")

    let file = CustomYAMLFile(fileURL: url)
    XCTAssertEqual(file.state, .absent)

    file.set("aqua", forPath: "style/color_scheme")
    file.set(18, forPath: "style/font_point")
    try file.save()

    let text = try String(contentsOf: url, encoding: .utf8)
    XCTAssertTrue(text.contains("patch:"))
    XCTAssertTrue(text.contains("aqua"))

    let reloaded = CustomYAMLFile(fileURL: url)
    XCTAssertEqual(reloaded.string(forPath: "style/color_scheme"), "aqua")
    XCTAssertEqual(reloaded.int(forPath: "style/font_point"), 18)
  }
}
