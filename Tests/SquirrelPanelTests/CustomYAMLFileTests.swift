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

  func testNormalizeIndentationReplacesLeadingSpecialSpace() {
    let input = "parent:\n\u{2005}child: value\n"
    let out = CustomYAMLFile.normalizeIndentation(input)
    XCTAssertEqual(out, "parent:\n child: value\n", "leading U+2005 must become a normal space")
  }

  func testNormalizeIndentationKeepsValueSpecialSpace() {
    let input = "format: \"a\u{2005}b\"\n"
    let out = CustomYAMLFile.normalizeIndentation(input)
    XCTAssertEqual(out, input, "special space inside a quoted value must be preserved")
  }

  func testLoadToleratesSpecialIndentWhitespace() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appending(path: UUID().uuidString)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appending(path: "squirrel.custom.yaml")
    // 用 U+2005 做缩进（旧版 rime-settings 的写法），以前会让文件进入只读。
    let yaml = "patch:\n\u{2005}style/color_scheme: aqua\n"
    try yaml.write(to: url, atomically: true, encoding: .utf8)

    let file = CustomYAMLFile(fileURL: url)
    XCTAssertTrue(file.isWritable, "含特殊空格缩进的文件仍应可写")
    XCTAssertEqual(file.string(forPath: "style/color_scheme"), "aqua")
  }
}
