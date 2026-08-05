//
//  RimeIceMergeTests.swift
//  Squirrel Panel
//
//  列表型托管合并算法与自定义短语文件的行为约束。
//  这两处直接决定「会不会弄丢用户配置」，必须有测试兜底。
//

import XCTest
@testable import SquirrelPanel

@MainActor
final class RimeIceMergeTests: XCTestCase {

  /// 出厂 filters 模板（照抄 rime_ice.schema.yaml 的顺序）
  private let templateFilters = [
    "lua_filter@*corrector",
    "reverse_lookup_filter@radical_reverse_lookup",
    "lua_filter@*autocap_filter",
    "lua_filter@*v_filter",
    "lua_filter@*pin_cand_filter",
    "lua_filter@*long_word_filter",
    "lua_filter@*reduce_english_filter",
    "simplifier@emoji",
    "simplifier@traditionalize",
    "lua_filter@*search@radical_pinyin",
    "uniquifier"
  ]

  private var managed: Set<String> { RimeIceConfigStore.managedFilters }

  // MARK: - 合并算法

  func testAllEnabledKeepsTemplateIdentical() {
    let result = RimeIceConfigStore.mergedList(template: templateFilters,
                                               current: templateFilters,
                                               managed: managed,
                                               isEnabled: { _ in true })
    XCTAssertEqual(result, templateFilters)
  }

  func testDisablingManagedItemRemovesOnlyThatItem() {
    let result = RimeIceConfigStore.mergedList(template: templateFilters,
                                               current: templateFilters,
                                               managed: managed,
                                               isEnabled: { $0 != "simplifier@emoji" })
    XCTAssertEqual(result, templateFilters.filter { $0 != "simplifier@emoji" })
    // 未托管项一个都不能少
    XCTAssertTrue(result.contains("simplifier@traditionalize"))
    XCTAssertTrue(result.contains("uniquifier"))
  }

  func testReEnablingRestoresTemplatePosition() {
    let without = templateFilters.filter { $0 != "simplifier@emoji" }
    let result = RimeIceConfigStore.mergedList(template: templateFilters,
                                               current: without,
                                               managed: managed,
                                               isEnabled: { _ in true })
    XCTAssertEqual(result, templateFilters)
    // 顺序锚点：置顶候选项 > Emoji > 简繁切换，长词优先 > Emoji
    let emoji = result.firstIndex(of: "simplifier@emoji")!
    XCTAssertLessThan(result.firstIndex(of: "lua_filter@*pin_cand_filter")!, emoji)
    XCTAssertLessThan(result.firstIndex(of: "lua_filter@*long_word_filter")!, emoji)
    XCTAssertLessThan(emoji, result.firstIndex(of: "simplifier@traditionalize")!)
  }

  func testUserAddedEntriesAreKeptInPlace() {
    var current = templateFilters
    current.insert("lua_filter@*my_own_filter", at: 1)
    let result = RimeIceConfigStore.mergedList(template: templateFilters,
                                               current: current,
                                               managed: managed,
                                               isEnabled: { _ in true })
    XCTAssertEqual(result, current)
    XCTAssertEqual(result.firstIndex(of: "lua_filter@*my_own_filter"), 1)
  }

  func testDuplicatesAreCollapsed() {
    let current = templateFilters + ["uniquifier"]
    let result = RimeIceConfigStore.mergedList(template: templateFilters,
                                               current: current,
                                               managed: managed,
                                               isEnabled: { _ in true })
    XCTAssertEqual(result, templateFilters)
  }

  func testRestoringIntoUserModifiedListUsesNearestAnchor() {
    // 用户删掉了 corrector（托管）并自己加了一条；此时把 emoji 关掉再开回来
    var current = templateFilters.filter { $0 != "simplifier@emoji" && $0 != "lua_filter@*corrector" }
    current.append("lua_filter@*my_own_filter")
    let result = RimeIceConfigStore.mergedList(template: templateFilters,
                                               current: current,
                                               managed: managed,
                                               isEnabled: { $0 != "lua_filter@*corrector" })
    // emoji 被插回 long_word 之后、traditionalize 之前
    let emoji = result.firstIndex(of: "simplifier@emoji")!
    XCTAssertLessThan(result.firstIndex(of: "lua_filter@*long_word_filter")!, emoji)
    XCTAssertLessThan(emoji, result.firstIndex(of: "simplifier@traditionalize")!)
    // 关闭的托管项不会被带回来，用户自定义条目仍在
    XCTAssertFalse(result.contains("lua_filter@*corrector"))
    XCTAssertTrue(result.contains("lua_filter@*my_own_filter"))
  }

  // MARK: - 自定义短语文件

  func testPhraseFileRoundTripKeepsCommentsAndTabs() throws {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "phrase-test-\(UUID().uuidString).txt")
    let original = """
    # Rime table
    #@/db_name\tcustom_phrase.txt
    #@/db_type\ttabledb

    邮箱\tyx\t100
    电话\tdh
    """
    try original.write(to: url, atomically: true, encoding: .utf8)
    defer {
      try? FileManager.default.removeItem(at: url)
      try? FileManager.default.removeItem(at: url.appendingPathExtension("bak"))
    }

    var file = CustomPhraseFile(fileURL: url)
    XCTAssertFalse(file.isDirty)
    XCTAssertEqual(file.entryCount, 2)
    XCTAssertEqual(file.serialize(), original)

    file.addEntry()
    XCTAssertTrue(file.isDirty)
    guard let newLine = file.lines.last else { return XCTFail("追加行丢失") }
    file.update(PhraseLine(id: newLine.id, word: "地址", code: "dz", weight: ""))
    try file.save()

    let reloaded = CustomPhraseFile(fileURL: url)
    XCTAssertFalse(reloaded.isDirty)
    XCTAssertEqual(reloaded.entryCount, 3)
    // 注释行、指令行原样保留
    XCTAssertTrue(reloaded.serialize().contains("#@/db_type\ttabledb"))
    // 权重为空时不写第三列
    XCTAssertTrue(reloaded.serialize().contains("地址\tdz"))
    XCTAssertFalse(reloaded.serialize().contains("地址\tdz\t"))
    // 写盘前留了 .bak
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: url.appendingPathExtension("bak").path(percentEncoded: false)))
  }

  func testPhraseFileAbsentGetsTableHeader() {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "phrase-missing-\(UUID().uuidString).txt")
    let file = CustomPhraseFile(fileURL: url)
    XCTAssertFalse(file.isDirty)
    XCTAssertEqual(file.entryCount, 0)
    XCTAssertTrue(file.serialize().contains("#@/db_type\ttabledb"))
  }
}
