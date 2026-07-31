//
//  RimeEnvironment.swift
//  Squirrel Panel
//
//  探测本机鼠须管（Squirrel）的安装状态与各项路径。
//  本面板不链接 librime，所有信息均通过文件系统与官方命令行接口获取。
//

import Foundation
import AppKit

/// 鼠须管在本机的安装与运行环境
struct RimeEnvironment {

  // MARK: - 固定路径

  /// 用户配置目录 ~/Library/Rime
  /// 与 Squirrel 的 Main.swift 保持一致：优先用 getpwuid 拿真实家目录，
  /// 这样即便进程运行在容器化环境里也能拿到正确路径。
  static let userDirectory: URL = {
    if let pwuid = getpwuid(getuid()) {
      return URL(fileURLWithFileSystemRepresentation: pwuid.pointee.pw_dir,
                 isDirectory: true,
                 relativeTo: nil)
        .appending(path: "Library", directoryHint: .isDirectory)
        .appending(path: "Rime", directoryHint: .isDirectory)
    }
    return FileManager.default
      .urls(for: .libraryDirectory, in: .userDomainMask)[0]
      .appending(path: "Rime", directoryHint: .isDirectory)
  }()

  /// 鼠须管应用本体的候选安装位置
  static let appCandidates: [URL] = [
    URL(fileURLWithPath: "/Library/Input Methods/Squirrel.app"),
    URL(fileURLWithPath: NSHomeDirectory() + "/Library/Input Methods/Squirrel.app")
  ]

  /// 日志目录（Squirrel 写在临时目录下）
  static var logDirectory: URL {
    FileManager.default.temporaryDirectory
      .appending(path: "rime.squirrel", directoryHint: .isDirectory)
  }

  /// 用户数据同步目录
  static var syncDirectory: URL {
    userDirectory.appending(path: "sync", directoryHint: .isDirectory)
  }

  // MARK: - 实例状态

  /// 已找到的 Squirrel.app 路径；nil 表示未安装
  let appURL: URL?
  /// 鼠须管版本号（CFBundleShortVersionString）
  let version: String?
  /// SharedSupport 目录，内置的 squirrel.yaml / default.yaml / 各输入方案都在这里
  let sharedSupportURL: URL?

  var isInstalled: Bool { appURL != nil }

  /// 用户目录是否已初始化（首次部署后才会生成 default.yaml 等文件）
  var isUserDirectoryReady: Bool {
    FileManager.default.fileExists(atPath: Self.userDirectory.path(percentEncoded: false))
  }

  /// 鼠须管进程是否正在运行
  var isRunning: Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: "im.rime.inputmethod.Squirrel").isEmpty
  }

  // MARK: - 探测

  static func detect() -> RimeEnvironment {
    let fm = FileManager.default
    guard let app = appCandidates.first(where: { fm.fileExists(atPath: $0.path(percentEncoded: false)) }) else {
      return RimeEnvironment(appURL: nil, version: nil, sharedSupportURL: nil)
    }
    let plistURL = app.appending(path: "Contents/Info.plist")
    var version: String?
    if let data = try? Data(contentsOf: plistURL),
       let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
      // 官方发行版只填了 CFBundleVersion，这里做一次回退
      version = (plist["CFBundleShortVersionString"] as? String)
        ?? (plist["CFBundleVersion"] as? String)
    }
    let shared = app.appending(path: "Contents/SharedSupport", directoryHint: .isDirectory)
    return RimeEnvironment(
      appURL: app,
      version: version,
      sharedSupportURL: fm.fileExists(atPath: shared.path(percentEncoded: false)) ? shared : nil
    )
  }

  // MARK: - 配置文件定位

  /// 按 Rime 的查找顺序返回某个配置文件的所有可能位置（用户目录优先于共享目录）
  func configSources(named name: String) -> [URL] {
    var urls: [URL] = [Self.userDirectory.appending(path: name)]
    if let shared = sharedSupportURL {
      urls.append(shared.appending(path: name))
    }
    return urls.filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
  }

  /// 读取内置 squirrel.yaml 原文；未安装时回退到打包在 App 内的官方副本
  func builtinSquirrelYAML() -> String {
    if let shared = sharedSupportURL {
      let url = shared.appending(path: "squirrel.yaml")
      if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
    }
    return BuiltinDefaults.squirrelYAML
  }
}
