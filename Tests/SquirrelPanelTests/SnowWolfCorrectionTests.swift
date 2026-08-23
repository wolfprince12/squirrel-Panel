//
//  SnowWolfCorrectionTests.swift
//  Squirrel Panel
//
//  雪狼智能纠错 v2：规则表自洽 + Swift↔Lua 契约（候选位置）。
//  纯静态检查，不实例化 RimeIceConfigStore，沙盒无 Rime 环境也能跑（不假绿）。
//

import XCTest
@testable import SquirrelPanel

@MainActor
final class SnowWolfCorrectionTests: XCTestCase {

  // MARK: - 规则表自洽

  /// 纠错规则非空、唯一、且一律为 derive（与模糊音同源的内核机制，零延迟）。
  /// 表为空 → 功能完全失效；有重复 → correctionRuleSet 与数组长度不一致，界面出现同名开关。
  func testCorrectionRulesIntegrity() {
    let rules = RimeIceConfigStore.correctionRules
    XCTAssertFalse(rules.isEmpty, "纠错规则表为空则功能完全失效")
    XCTAssertEqual(RimeIceConfigStore.correctionRuleSet.count, rules.count,
                   "纠错规则有重复，correctionRuleSet 与数组长度不一致")
    for r in rules {
      XCTAssertTrue(r.rule.hasPrefix("derive/"), "纠错规则只能是 derive：\(r.rule)")
    }
  }

  // MARK: - Swift↔Lua 枚举契约

  /// 候选位置枚举的 `name` 必须严格等于 lua 读取的 txt 值（top/afterFirst）。
  /// 一旦对不上，Swift 写入 correction_position.txt 后 lua 读到的字符串不匹配 →
  /// 纠错候选位置静默失效（最隐蔽的回归）。
  func testCorrectionEnumNamesMatchLuaContract() {
    XCTAssertEqual(CorrectionInjectionPosition.top.name, "top")
    XCTAssertEqual(CorrectionInjectionPosition.afterFirst.name, "afterFirst")
  }
}
