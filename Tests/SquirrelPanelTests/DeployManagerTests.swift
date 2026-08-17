//
//  DeployManagerTests.swift
//  Squirrel Panel
//
//  部署 YAML 错误精确诊断内核的回归用例。
//  parseBuildErrors 是正则驱动、确定性、不依赖运行机器是否装了鼠须管，
//  因此可以在任何环境（含 CI）真跑，防止「改了不生效」的诊断定位静默失效。
//

import XCTest
@testable import SquirrelPanel

final class DeployManagerTests: XCTestCase {

  // MARK: - 单条错误（与本项目实测格式一致）

  func testParsesSingleYAMLErrorWithLineAndColumn() {
    // 本机实测的真实日志格式（config_data.cc 前缀 + 完整路径 + ./ 相对段）
    let log = "E20260817 14:03:11.123 config_data.cc:78] Error parsing YAML \"/Users/wolfprince/Library/Rime/./default.custom.yaml\" : yaml-cpp: error at line 3, column 3: end of map not found"
    let issues = DeployManager.parseBuildErrors(log)
    XCTAssertEqual(issues.count, 1)
    let issue = issues[0]
    XCTAssertEqual(issue.fileName, "default.custom.yaml")
    XCTAssertEqual(issue.line, 3)
    XCTAssertEqual(issue.column, 3)
    XCTAssertEqual(issue.message, "end of map not found")
    // ./ 相对段应被标准化掉，且以文件名结尾
    XCTAssertTrue(issue.path.hasSuffix("default.custom.yaml"))
    XCTAssertFalse(issue.path.contains("/./"))
    XCTAssertEqual(issue.raw, log)
  }

  // MARK: - 多条错误（不同文件）

  func testParsesMultipleErrorsAcrossFiles() {
    let log = """
      E... config_data.cc:78] Error parsing YAML "/Users/wolfprince/Library/Rime/./default.custom.yaml" : yaml-cpp: error at line 3, column 3: end of map not found
      E... config_data.cc:78] Error parsing YAML "/Users/wolfprince/Library/Rime/./squirrel.custom.yaml" : yaml-cpp: error at line 12, column 1: mapping values are not allowed here
      """
    let issues = DeployManager.parseBuildErrors(log)
    XCTAssertEqual(issues.count, 2)

    let first = issues[0]
    XCTAssertEqual(first.fileName, "default.custom.yaml")
    XCTAssertEqual(first.line, 3)
    XCTAssertEqual(first.column, 3)

    let second = issues[1]
    XCTAssertEqual(second.fileName, "squirrel.custom.yaml")
    XCTAssertEqual(second.line, 12)
    XCTAssertEqual(second.column, 1)
    // 消息里含冒号也不应截断
    XCTAssertEqual(second.message, "mapping values are not allowed here")
  }

  // MARK: - 干净日志

  func testReturnsEmptyForCleanLog() {
    let log = """
      [INFO] starting deploy
      [INFO] build succeeded, 0 errors
      """
    let issues = DeployManager.parseBuildErrors(log)
    XCTAssertTrue(issues.isEmpty)
  }

  // MARK: - 含 "Error parsing YAML" 但不符合既定格式（不应静默误判）

  func testSkipsNonMatchingErrorLines() {
    // 含关键字但格式不同，正则不应误命中
    let log = "Error parsing YAML: unknown failure"
    let issues = DeployManager.parseBuildErrors(log)
    XCTAssertTrue(issues.isEmpty)
  }

  // MARK: - 消息首尾空白应被修剪

  func testTrimsSurroundingWhitespaceInMessage() {
    let log = "Error parsing YAML \"/x/y.custom.yaml\" : yaml-cpp: error at line 5, column 2:   缩进不匹配   "
    let issues = DeployManager.parseBuildErrors(log)
    XCTAssertEqual(issues.count, 1)
    XCTAssertEqual(issues[0].message, "缩进不匹配")
  }
}
