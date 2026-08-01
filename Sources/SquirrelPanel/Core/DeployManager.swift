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
