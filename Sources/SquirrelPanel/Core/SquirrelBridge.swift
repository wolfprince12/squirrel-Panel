//
//  SquirrelBridge.swift
//  Squirrel Panel
//
//  与鼠须管进程通信。
//
//  鼠须管在 Main.swift 中提供了一套官方命令行接口，并在
//  SquirrelApplicationDelegate 中监听若干分布式通知。本面板只使用这些
//  公开通道，不加载 librime、不注入进程，因此不受其内部实现变动影响。
//

import Foundation
import AppKit

enum SquirrelBridge {

  /// 鼠须管监听的分布式通知
  private enum Notify {
    static let reload = "SquirrelReloadNotification"
    static let sync = "SquirrelSyncNotification"
    static let toggleASCII = "SquirrelToggleASCIIModeNotification"
  }

  // MARK: - 部署

  /// 重新部署，让改动生效。
  ///
  /// 鼠须管在后台运行，AppKit 会暂停向非活跃 App 投递分布式通知，
  /// 因此必须使用 deliverImmediately。这一点在上游源码里有明确注释。
  static func deploy(environment: RimeEnvironment) throws {
    if environment.isRunning {
      DistributedNotificationCenter.default().postNotificationName(
        .init(Notify.reload), object: nil, userInfo: nil, deliverImmediately: true)
    } else {
      // 进程没跑，直接调 CLI 让它自己完成一次部署
      try runCLI(["--reload"], environment: environment)
    }
  }

  /// 同步用户数据
  static func sync(environment: RimeEnvironment) throws {
    if environment.isRunning {
      DistributedNotificationCenter.default().postNotificationName(
        .init(Notify.sync), object: nil, userInfo: nil, deliverImmediately: true)
    } else {
      try runCLI(["--sync"], environment: environment)
    }
  }

  /// 切换中英文输入状态
  static func setASCIIMode(_ ascii: Bool) {
    DistributedNotificationCenter.default().postNotificationName(
      .init(Notify.toggleASCII),
      object: ascii ? "ascii" : "nascii",
      userInfo: nil,
      deliverImmediately: true)
  }

  /// 重启鼠须管进程（部分改动如输入源注册需要重启才生效）
  static func restart(environment: RimeEnvironment) throws {
    guard let appURL = environment.appURL else { throw PanelError.squirrelNotInstalled }
    _ = try? runCLI(["--quit"], environment: environment)
    Thread.sleep(forTimeInterval: 0.6)
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
  }

  // MARK: - 命令行

  @discardableResult
  static func runCLI(_ arguments: [String], environment: RimeEnvironment) throws -> String {
    guard let appURL = environment.appURL else { throw PanelError.squirrelNotInstalled }
    let exec = appURL.appending(path: "Contents/MacOS/Squirrel")
    let task = Process()
    task.executableURL = exec
    task.arguments = arguments
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    try task.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else {
      throw PanelError.commandFailed("Squirrel " + arguments.joined(separator: " "),
                                     task.terminationStatus)
    }
    return String(data: data, encoding: .utf8) ?? ""
  }

  // MARK: - 访达

  static func reveal(_ url: URL) {
    if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path(percentEncoded: false))
  }
}
