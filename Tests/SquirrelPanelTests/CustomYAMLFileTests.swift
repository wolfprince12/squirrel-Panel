//
//  CustomYAMLFileTests.swift
//  SquirrelPanelTests
//
//  验证逐行手术式写入（applyLineEdits）的核心行为：
//  - 保留用户注释与行尾注释
//  - 行级删除托管键
//  - 字典/列表-of-映射块的整体替换（punctuator / key_bindings / preset_color_schemes）
//  - 写后回读校验（WriteVerifier）
//

import XCTest
@testable import SquirrelPanel

final class CustomYAMLFileTests: XCTestCase {

  var tmpDir: URL!

  override func setUp() {
    tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("sp-yaml-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tmpDir)
  }

  // MARK: - 注释保留

  func testApplyLineEditsPreservesComments() throws {
    let url = tmpDir.appendingPathComponent("squirrel.custom.yaml")
    let original = """
    # 用户手写的注释，不能丢
    patch:
      style/color_scheme: native   # 行尾注释
      # 另一行注释
      menu/page_size: 5
    """
    try original.write(to: url, atomically: true, encoding: .utf8)

    let file = CustomYAMLFile(fileURL: url)
    var set: PatchSet = [:]
    set["style/color_scheme"] = .string("azure")
    set["menu/page_size"] = .int(9)
    try file.applyLineEdits(set)

    let result = try String(contentsOf: url, encoding: .utf8)
    XCTAssertTrue(result.contains("# 用户手写的注释，不能丢"), "顶层注释应保留")
    XCTAssertTrue(result.contains("# 另一行注释"), "节内注释应保留")
    XCTAssertTrue(result.contains("style/color_scheme: azure"), "标量值应更新")
    XCTAssertTrue(result.contains("# 行尾注释"), "行尾注释应保留")
    XCTAssertTrue(result.contains("menu/page_size: 9"), "第二个标量键应更新")
  }

  // MARK: - 行级删键

  func testApplyLineEditsRemovesKey() throws {
    let url = tmpDir.appendingPathComponent("squirrel.custom.yaml")
    let original = """
    patch:
      style/color_scheme: native
      menu/page_size: 5
    """
    try original.write(to: url, atomically: true, encoding: .utf8)

    let file = CustomYAMLFile(fileURL: url)
    var set: PatchSet = [:]
    set["menu/page_size"] = PatchValue?.none
    try file.applyLineEdits(set)

    let result = try String(contentsOf: url, encoding: .utf8)
    XCTAssertTrue(result.contains("style/color_scheme: native"), "未删除的键应保留")
    XCTAssertFalse(result.contains("menu/page_size"), "标 nil 的键应被删除")
  }

  // MARK: - 块替换：字典与列表

  func testApplyLineEditsBlockDictionary() throws {
    let url = tmpDir.appendingPathComponent("default.custom.yaml")
    try "patch:\n".write(to: url, atomically: true, encoding: .utf8)

    let file = CustomYAMLFile(fileURL: url)
    var set: PatchSet = [:]
    set["punctuator/full_shape"] = .punctuation(["，": ["、", "，"]])
    try file.applyLineEdits(set)

    let result = try String(contentsOf: url, encoding: .utf8)
    XCTAssertTrue(result.contains("punctuator/full_shape:"), "字典键应写入")
    // 中文键/值由 Yams 往返序列化决定引号形式（裸写或加引号皆可），不约束具体样式，
    // 只校验「落盘后重读回的值与源一致」这一真正目标。
    let reloaded = CustomYAMLFile(fileURL: url)
    let dict = reloaded.value(forPath: "punctuator/full_shape") as? [String: Any]
    XCTAssertEqual(dict?["，"] as? [String], ["、", "，"], "字典键与值须经往返序列化保持正确")
  }

  func testApplyLineEditsBlockListOfMaps() throws {
    let url = tmpDir.appendingPathComponent("default.custom.yaml")
    try "patch:\n".write(to: url, atomically: true, encoding: .utf8)

    let file = CustomYAMLFile(fileURL: url)
    var set: PatchSet = [:]
    set["key_bindings"] = .keyBindings([
      ["when": "has_menu", "accept": "Tab", "send": "Page_Down"],
      ["when": "has_menu", "accept": "Shift+Tab", "send": "Page_Up"],
    ])
    try file.applyLineEdits(set)

    let result = try String(contentsOf: url, encoding: .utf8)
    XCTAssertTrue(result.contains("key_bindings:"), "列表键应写入")
    XCTAssertTrue(result.contains("- accept: Tab"), "列表项首行应带 - 前缀")
    XCTAssertTrue(result.contains("  send: Page_Down"), "列表项续行应缩进对齐")
    XCTAssertTrue(result.contains("- accept: Shift+Tab"), "第二项应正确渲染")
  }

  // MARK: - 配色预设定义（单映射块）

  func testApplyLineEditsPresetDefinition() throws {
    let url = tmpDir.appendingPathComponent("squirrel.custom.yaml")
    try "patch:\n".write(to: url, atomically: true, encoding: .utf8)

    let file = CustomYAMLFile(fileURL: url)
    var set: PatchSet = [:]
    set["preset_color_schemes/abc"] = .dictionary([
      "name": "ABC",
      "text_color": "0xFFFFFF",
      "back_color": "0x000000",
    ])
    try file.applyLineEdits(set)

    let result = try String(contentsOf: url, encoding: .utf8)
    XCTAssertTrue(result.contains("preset_color_schemes/abc:"), "配色预设键应写入")
    // 颜色值 0xFFFFFF 经 Yams 落盘可能被加引号保护（保持字符串、避免被写成十进制）；
    // 不约束具体引号形式，只校验「重读回的值仍为字符串 0xFFFFFF」这一真正目标。
    let reloaded = CustomYAMLFile(fileURL: url)
    let scheme = reloaded.value(forPath: "preset_color_schemes/abc") as? [String: Any]
    XCTAssertEqual(scheme?["name"] as? String, "ABC", "预设字段应写入")
    XCTAssertEqual(scheme?["text_color"] as? String, "0xFFFFFF", "颜色值须以字符串 0xFFFFFF 落盘，不得被改写成十进制")
    XCTAssertEqual(scheme?["back_color"] as? String, "0x000000")
  }

  // MARK: - 删光托管键不丢其它内容

  func testApplyLineEditsClearManagedKeepsUserContent() throws {
    let url = tmpDir.appendingPathComponent("squirrel.custom.yaml")
    let original = """
    patch:
      style/color_scheme: native
      # 用户注释
      app_options/com.xxx/ascii_mode: true
    """
    try original.write(to: url, atomically: true, encoding: .utf8)

    let file = CustomYAMLFile(fileURL: url)
    var set: PatchSet = [:]
    set["style/color_scheme"] = PatchValue?.none
    set["app_options/com.xxx/ascii_mode"] = PatchValue?.none
    try file.applyLineEdits(set)

    let result = try String(contentsOf: url, encoding: .utf8)
    XCTAssertFalse(result.contains("style/color_scheme"), "托管键应删除")
    XCTAssertFalse(result.contains("ascii_mode"), "托管键应删除")
    XCTAssertTrue(result.contains("# 用户注释"), "用户注释应保留")
  }

  // MARK: - 写后回读校验（WriteVerifier）

  func testWriteVerifierPassAndFail() throws {
    let url = tmpDir.appendingPathComponent("v.yaml")
    let text = "patch:\n  style/color_scheme: azure\n"
    try text.write(to: url, atomically: true, encoding: .utf8)

    // 1. 期望值一致：通过
    var ok: PatchSet = [:]
    ok["style/color_scheme"] = .string("azure")
    XCTAssertNoThrow(try WriteVerifier.verify(fileURL: url, patchSet: ok))

    // 2. 期望值不符：抛错
    var mismatch: PatchSet = [:]
    mismatch["style/color_scheme"] = .string("native")
    XCTAssertThrowsError(try WriteVerifier.verify(fileURL: url, patchSet: mismatch))

    // 3. 期望存在但缺失的键：抛错
    var missing: PatchSet = [:]
    missing["menu/page_size"] = .int(5)
    XCTAssertThrowsError(try WriteVerifier.verify(fileURL: url, patchSet: missing))

    // 4. 期望删除却仍存在的键：抛错
    var shouldRemove: PatchSet = [:]
    shouldRemove["style/color_scheme"] = PatchValue?.none
    XCTAssertThrowsError(try WriteVerifier.verify(fileURL: url, patchSet: shouldRemove))
  }
}
