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
import UniformTypeIdentifiers
import Yams

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
    // 防事故：部署前校验当前启用方案的全部源文件是否齐备。
    // 鼠须管接到 SquirrelReloadNotification 后会执行一次完整方案重建（deploy）。
    // 若某方案 .schema.yaml 源文件缺失，重建会失败、输入法直接失效。
    // 因此一旦检测到缺失，立刻中止部署并抛出明确错误，绝不引爆输入法。
    let missing = missingSchemaSources(environment: environment)
    guard missing.isEmpty else {
      throw PanelError.schemaSourcesMissing(missing)
    }
    if environment.isRunning {
      DistributedNotificationCenter.default().postNotificationName(
        .init(Notify.reload), object: nil, userInfo: nil, deliverImmediately: true)
    } else {
      // 进程没跑，直接调 CLI 让它自己完成一次部署
      try runCLI(["--reload"], environment: environment)
    }
    // 防复发：本机 Squirrel 的部署只把产物落到 build/、不回填顶层，
    // 导致顶层 .bin 被清空、中文无法输入。部署后回填 build/ 编译产物到顶层。
    scheduleRestoreBinariesFromBuild()
  }

  // MARK: - 部署后回填（防复发）

  /// 部署后把 `build/` 编译产物回填顶层 `~/Library/Rime/`。
  /// 本机 Squirrel 的部署只把产物暂存到 `build/`、不回填顶层，
  /// 导致顶层 `.bin` 被清空、中文无法输入。此函数等 Squirrel 编译完再拷回，杜绝复发。
  private static func scheduleRestoreBinariesFromBuild() {
    let start = Date()
    let fm = FileManager.default
    let top = RimeEnvironment.userDirectory
    let build = top.appending(path: "build")
    let deadline = start.addingTimeInterval(90)
    DispatchQueue.global(qos: .utility).async {
      while Date() < deadline {
        let prism = build.appending(path: "rime_ice.prism.bin")
        guard let mtime = try? fm.attributesOfItem(atPath: prism.path(percentEncoded: false))[.modificationDate] as? Date,
              mtime > start,                          // 必须是本次部署后新编译的
              Date().timeIntervalSince(mtime) > 1.5   // 且 mtime 已稳定（编译结束）
        else {
          Thread.sleep(forTimeInterval: 0.5)
          continue
        }
        Self.copyBuildToTopLevel()
        return
      }
      // 超时也兜底拷一次，尽量恢复输入法
      Self.copyBuildToTopLevel()
    }
  }

  /// 把 `build/` 下的编译产物（.bin / .yaml）复制回顶层用户目录。
  private static func copyBuildToTopLevel() {
    let fm = FileManager.default
    let top = RimeEnvironment.userDirectory
    let build = top.appending(path: "build")
    guard let files = try? fm.contentsOfDirectory(at: build, includingPropertiesForKeys: nil) else { return }
    for url in files {
      guard !url.hasDirectoryPath else { continue }
      let ext = url.pathExtension.lowercased()
      guard ["bin", "yaml"].contains(ext) else { continue }
      let dst = top.appending(path: url.lastPathComponent)
      try? fm.removeItem(at: dst)
      try? fm.copyItem(at: url, to: dst)
    }
  }

  /// 异步部署：把同步且会阻塞的部署（含 Squirrel CLI `waitUntilExit`、整套方案重建）
  /// 放到后台线程执行，返回一个可在主线程 `await` 的挂起点。
  /// 调用方（如 SettingsStore.apply）即可 `await` 它而不阻塞 UI 线程。
  static func deployAsync(environment: RimeEnvironment) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          try Self.deploy(environment: environment)
          cont.resume()
        } catch {
          cont.resume(throwing: error)
        }
      }
    }
  }

  // MARK: - 部署前校验

  /// 当前配置实际启用的方案 id（合并 squirrel.yaml / default.custom.yaml / default.yaml）
  private static func enabledSchemaIDs(environment: RimeEnvironment) -> [String] {
    var ids: [String] = []
    var seen = Set<String>()
    let candidates = [
      RimeEnvironment.userDirectory.appending(path: "default.custom.yaml"),
      RimeEnvironment.userDirectory.appending(path: "squirrel.yaml"),
      environment.sharedSupportURL?.appending(path: "default.yaml")
    ].compactMap { $0 }
    for url in candidates {
      guard let text = try? String(contentsOf: url, encoding: .utf8),
            let obj = try? Yams.load(yaml: text) as? [String: Any],
            let list = obj["schema_list"] as? [Any] else { continue }
      for item in list {
        let id: String? = {
          if let dict = item as? [String: Any] { return dict["schema"] as? String }
          return item as? String
        }()
        if let id, !seen.contains(id) { seen.insert(id); ids.append(id) }
      }
    }
    return ids
  }

  /// 缺失源文件的启用方案 id 列表
  private static func missingSchemaSources(environment: RimeEnvironment) -> [String] {
    enabledSchemaIDs(environment: environment).filter { !hasSchemaSource($0, environment: environment) }
  }

  /// 某方案的源文件是否齐备（用户目录或 SharedSupport 任一存在即可）
  private static func hasSchemaSource(_ id: String, environment: RimeEnvironment) -> Bool {
    let fm = FileManager.default
    let user = RimeEnvironment.userDirectory.appending(path: "\(id).schema.yaml")
    if fm.fileExists(atPath: user.path(percentEncoded: false)) { return true }
    if let shared = environment.sharedSupportURL {
      let s = shared.appending(path: "\(id).schema.yaml")
      if fm.fileExists(atPath: s.path(percentEncoded: false)) { return true }
    }
    return false
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

  // MARK: - 用户词库（rime_dict_manager）

  /// 调用鼠须管自带的 `rime_dict_manager` 列出 / 导出 / 导入用户词库。
  /// 该二进制与 Squirrel 同目录（Contents/MacOS/rime_dict_manager），无需链接 librime。
  /// 返回合并后的标准输出与标准错误文本。退出码非 0 时抛出 PanelError。
  @discardableResult
  static func runDictManager(_ arguments: [String], environment: RimeEnvironment) throws -> String {
    guard let appURL = environment.appURL else { throw PanelError.squirrelNotInstalled }
    let exec = appURL.appending(path: "Contents/MacOS/rime_dict_manager")
    let task = Process()
    task.executableURL = exec
    task.arguments = arguments
    let out = Pipe()
    let err = Pipe()
    task.standardOutput = out
    task.standardError = err
    try task.run()
    task.waitUntilExit()
    let text = (String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
      + (String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    guard task.terminationStatus == 0 else {
      throw PanelError.commandFailed("rime_dict_manager " + arguments.joined(separator: " "),
                                     task.terminationStatus)
    }
    return text
  }

  // MARK: - 访达

  static func reveal(_ url: URL) {
    if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path(percentEncoded: false))
  }

  /// 为指定目录合成「标准文件夹 + 鼠须管控制面板 logo」图标（如 RimeSync 同步目录）。
  /// 图标直接浮于文件夹正面，无白色底板，带轻微阴影以贴合文件夹透视。
  /// 此为尽力而为操作：即使图标设置失败，也不影响目录创建与同步配置。
  static func setFolderIcon(at url: URL) {
    guard let logoURL = Bundle.main.url(forResource: "AppLogo", withExtension: "png"),
          let logo = NSImage(contentsOf: logoURL) else { return }

    let folderIcon = NSWorkspace.shared.icon(for: .folder)
    let px: CGFloat = 1024
    let logicalSize = NSSize(width: px / 2, height: px / 2)

    guard let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(px),
      pixelsHigh: Int(px),
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ), let ctx = NSGraphicsContext(bitmapImageRep: bitmap) else { return }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    defer { NSGraphicsContext.restoreGraphicsState() }

    let fullRect = NSRect(x: 0, y: 0, width: px, height: px)

    // 1. 标准蓝色文件夹底图
    folderIcon.draw(in: fullRect, from: .zero, operation: .copy, fraction: 1.0)

    // 2. 鼠须管控制面板 logo 直接浮于文件夹正面，无白色底板
    let logoScale: CGFloat = 0.55
    let logoSize = px * logoScale
    let logoRect = NSRect(
      x: (px - logoSize) / 2,
      y: px * 0.170,
      width: logoSize,
      height: logoSize
    )

    ctx.cgContext.setShadow(
      offset: CGSize(width: 0, height: -px * 0.018),
      blur: px * 0.030,
      color: NSColor.black.withAlphaComponent(0.22).cgColor)

    logo.draw(in: logoRect, from: .zero, operation: .sourceOver, fraction: 1.0)

    ctx.cgContext.setShadow(offset: .zero, blur: 0, color: nil)

    let composed = NSImage(size: logicalSize)
    composed.addRepresentation(bitmap)
    NSWorkspace.shared.setIcon(composed, forFile: url.path(percentEncoded: false), options: [])
  }
}
