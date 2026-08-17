//
//  DeployManager.swift
//  Squirrel Panel
//
//  部署排障内核：触发一次重新部署，并尽可能客观地判断其成败。
//
//  设计取舍：本机验证发现 ~/Library/Rime/rime.log 与 /tmp/rime.squirrel
//  在很多环境下并不存在，因此不依赖日志文件，而是：
//    1. 触发部署（Squirrel 运行时发分布式通知；未运行时直接调 CLI --build 抓取文本输出）；
//    2. 轮询 build/ 目录的编译产物（.prism.bin / .table.bin）直到稳定；
//    3. 重新扫描可用方案，对比「已启用但不可用」的方案，给出排障结论。
//

import Foundation
import AppKit

struct DeployReport {
  var success: Bool
  var logText: String
  var buildOutput: String
  var availableSchemas: [RimeSchema]
  var enabledSchemaIDs: [String]
  var missingSchemaIDs: [String]
  var durationMs: Int
}

enum DeployManager {

  /// 触发部署并等待其完成，返回可读的部署报告。
  static func deployAndReport(environment: RimeEnvironment) async -> DeployReport {
    let start = Date()
    let running = environment.isRunning
    var buildOutput = ""

    if running {
      DistributedNotificationCenter.default().postNotificationName(
        .init("SquirrelReloadNotification"), object: nil, userInfo: nil, deliverImmediately: true)
      _ = await pollBuildDirectory(environment: environment, timeout: 25)
    } else if let appURL = environment.appURL {
      let exec = appURL.appending(path: "Contents/MacOS/Squirrel")
      let task = Process()
      task.executableURL = exec
      task.arguments = ["--build"]
      let out = Pipe(); let err = Pipe()
      task.standardOutput = out; task.standardError = err
      try? task.run()
      task.waitUntilExit()
      let data = out.fileHandleForReading.readDataToEndOfFile()
      let edata = err.fileHandleForReading.readDataToEndOfFile()
      buildOutput = (String(data: data, encoding: .utf8) ?? "")
        + (String(data: edata, encoding: .utf8) ?? "")
    }

    // 重新扫描方案与启用状态
    let available = SchemaCatalog.scan(environment: environment)
    let defaultPatch = CustomYAMLFile(fileURL: RimeEnvironment.userDirectory
      .appending(path: "default.custom.yaml"))
    let enabled = SchemaCatalog.enabledSchemaIDs(patch: defaultPatch, environment: environment)

    // 缺失判定：启用的方案要么没有 .schema.yaml，要么 build/ 里没生成 .prism.bin
    var missing: [String] = []
    for id in enabled {
      let hasSchema = available.contains { $0.id == id }
      let prism = RimeEnvironment.userDirectory
        .appending(path: "build").appending(path: "\(id).prism.bin")
      let built = FileManager.default.fileExists(atPath: prism.path(percentEncoded: false))
      if !hasSchema || !built {
        missing.append(id)
      }
    }

    let duration = Int(Date().timeIntervalSince(start) * 1000)
    let fatal = buildOutput.lowercased().contains("error:")
      || (buildOutput.lowercased().contains("not found")
          && buildOutput.lowercased().contains("schema"))
    let success = missing.isEmpty && !fatal

    let log: String
    if !buildOutput.isEmpty {
      log = buildOutput
    } else if missing.isEmpty {
      log = String(localized: "deploy.logClean")
    } else {
      log = String(format: String(localized: "deploy.logMissing"), missing.joined(separator: ", "))
    }

    return DeployReport(
      success: success,
      logText: log,
      buildOutput: buildOutput,
      availableSchemas: available,
      enabledSchemaIDs: enabled,
      missingSchemaIDs: missing,
      durationMs: duration)
  }

  // MARK: - 部署 YAML 错误精确诊断

  /// 一条配置错误
  struct ConfigIssue: Identifiable {
    var id = UUID()
    /// 文件名（展示用，如 default.custom.yaml）
    let fileName: String
    /// 完整路径（用于「在访达中打开」）
    let path: String
    let line: Int?
    let column: Int?
    let message: String
    /// 原始日志行（展开「详细日志」时用）
    let raw: String
  }

  /// 诊断结果
  struct DiagnoseResult {
    var issues: [ConfigIssue] = []
    var rawLog: String = ""
    var durationMs: Int = 0
    var didStopSquirrel = false
  }

  /// 运行一次「构建」并精确捕获其中的 YAML 解析错误，给出文件 + 行号 + 列号 + 修正建议。
  ///
  /// 诊断必须拿到 `--build` 的命令行文本输出（DeployManager.deployAndReport 在
  /// 鼠须管运行时走分布式通知、不抓文本，因此无法定位错误）。本方法强制走 CLI 路径：
  /// 若鼠须管正在运行，先退出它再构建，构建完再把它拉起来，全程对用户透明。
  static func diagnose(environment: RimeEnvironment) async -> DiagnoseResult {
    let start = Date()
    let wasRunning = environment.isRunning

    if wasRunning {
      quitAndWait(environment: environment)
    }

    let buildOutput = captureBuild(environment: environment)

    if wasRunning, let appURL = environment.appURL {
      let config = NSWorkspace.OpenConfiguration()
      config.activates = false
      NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
    }

    let issues = parseBuildErrors(buildOutput)
    return DiagnoseResult(
      issues: issues,
      rawLog: buildOutput.isEmpty
        ? String(localized: "diagnose.logEmpty")
        : buildOutput,
      durationMs: Int(Date().timeIntervalSince(start) * 1000),
      didStopSquirrel: wasRunning)
  }

  /// 退出鼠须管并等待其进程退出（最多 ~4s），确保 CLI --build 独占用户词库锁
  private static func quitAndWait(environment: RimeEnvironment) {
    guard let appURL = environment.appURL else { return }
    let exec = appURL.appending(path: "Contents/MacOS/Squirrel")
    let task = Process()
    task.executableURL = exec
    task.arguments = ["--quit"]
    try? task.run()
    task.waitUntilExit()
    // 给进程一点时间真正退出
    for _ in 0..<20 {
      if !environment.isRunning { return }
      Thread.sleep(forTimeInterval: 0.2)
    }
  }

  /// 运行 `Squirrel --build` 并捕获标准输出 + 标准错误文本
  private static func captureBuild(environment: RimeEnvironment) -> String {
    guard let appURL = environment.appURL else { return "" }
    let exec = appURL.appending(path: "Contents/MacOS/Squirrel")
    let task = Process()
    task.executableURL = exec
    task.arguments = ["--build"]
    let out = Pipe()
    let err = Pipe()
    task.standardOutput = out
    task.standardError = err
    try? task.run()
    task.waitUntilExit()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let edata = err.fileHandleForReading.readDataToEndOfFile()
    return (String(data: data, encoding: .utf8) ?? "")
      + (String(data: edata, encoding: .utf8) ?? "")
  }

  /// 从构建日志中解析出所有 `Error parsing YAML "<path>" : yaml-cpp: error at line N, column M: <msg>`
  /// 已在本机实测，格式稳定（见 squirrel.custom.yaml / default.custom.yaml 的缩进/括号错误）。
  static func parseBuildErrors(_ text: String) -> [ConfigIssue] {
    var result: [ConfigIssue] = []
    let pattern = #"Error parsing YAML\s+"([^"]+)"\s*:\s*yaml-cpp: error at line (\d+), column (\d+):\s*(.*)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
    for line in text.components(separatedBy: "\n") where line.contains("Error parsing YAML") {
      let ns = line as NSString
      guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
            m.numberOfRanges == 5 else { continue }
      let path = ns.substring(with: m.range(at: 1))
      let lineNo = Int(ns.substring(with: m.range(at: 2)))
      let colNo = Int(ns.substring(with: m.range(at: 3)))
      let msg = ns.substring(with: m.range(at: 4)).trimmingCharacters(in: .whitespaces)
      let fileName = (path as NSString).lastPathComponent
      result.append(ConfigIssue(
        fileName: fileName,
        path: (path as NSString).standardizingPath,
        line: lineNo,
        column: colNo,
        message: msg,
        raw: line))
    }
    return result
  }

  /// 轮询 build/ 目录，直到 .bin 文件稳定（1.5s 内无变化）或超时
  private static func pollBuildDirectory(environment: RimeEnvironment, timeout: TimeInterval) async -> Bool {
    let buildDir = RimeEnvironment.userDirectory.appending(path: "build")
    func snapshot() -> [String: TimeInterval] {
      guard let urls = try? FileManager.default.contentsOfDirectory(
        at: buildDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [:] }
      var map: [String: TimeInterval] = [:]
      for u in urls where u.pathExtension == "bin" {
        let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate?.timeIntervalSince1970 ?? 0
        map[u.lastPathComponent] = m
      }
      return map
    }
    let deadline = Date().addingTimeInterval(timeout)
    var last = snapshot()
    var stableSince: Date?
    while Date() < deadline {
      try? await Task.sleep(nanoseconds: 500_000_000)
      let now = snapshot()
      if now == last {
        if stableSince == nil { stableSince = Date() }
        else if Date().timeIntervalSince(stableSince!) >= 1.5 { return true }
      } else {
        stableSince = nil
        last = now
      }
    }
    return false
  }
}
