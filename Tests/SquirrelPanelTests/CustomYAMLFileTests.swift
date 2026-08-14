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

  // 回归测试：手写 0x 十六进制颜色在「重新部署」后被改写成十进制（GitHub issue）。
  // 模拟用户在 rime_ice.custom.yaml 里加了自定义皮肤，面板读回又写盘的场景：
  // 0x6EC800 必须原样保留，绝不能变成 7251968。
  func testHexColorSurvivesRoundTrip() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appending(path: UUID().uuidString)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appending(path: "rime_ice.custom.yaml")
    let yaml = """
    patch:
      preset_color_schemes:
        my_skin:
          name: My Skin
          author: tester
          back_color: 0x6EC800
          text_color: 0x000000
          hilited_candidate_back_color: 0xCCEDC7
    """
    try yaml.write(to: url, atomically: true, encoding: .utf8)

    let file = CustomYAMLFile(fileURL: url)
    XCTAssertTrue(file.isWritable)
    // 载入后，颜色值应作为字符串保留，而非被解析成整数
    XCTAssertEqual(file.string(forPath: "preset_color_schemes/my_skin/back_color"), "0x6EC800")

    // 重新保存，模拟「重新部署」动作
    try file.save()
    let out = try String(contentsOf: url, encoding: .utf8)
    XCTAssertTrue(out.contains("0x6EC800"), "十六进制颜色必须原样保留，实际写出：\n\(out)")
    XCTAssertFalse(out.contains("7251968"), "颜色绝不能被改写成十进制整数")
  }
}
