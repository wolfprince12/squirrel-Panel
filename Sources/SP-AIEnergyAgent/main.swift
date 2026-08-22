//
//  SP-AIEnergyAgent.swift
//  SP-AIEnergyAgent — Squirrel Panel AI Energy Resident Agent
//
//  长期驻留系统的独立后台进程：
//  - 在系统栏显示小老鼠图标（可由用户切换图标）；
//  - 读取运行时配置，为主面板提供常驻外壳（AI 引擎由后续阶段接入）；
//  - 监听配置文件变化，与主面板解耦；
//  - 主面板关闭或重启不影响本进程。
//

import Foundation
import AppKit

// MARK: - 路径

func appSupportDir() -> URL {
  let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  let dir = base.appendingPathComponent("SquirrelPanel", isDirectory: true)
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
}

func runtimeConfigURL() -> URL { appSupportDir().appendingPathComponent("aienergy_config.json") }
func statusURL() -> URL { appSupportDir().appendingPathComponent("aienergy_status.json") }
func pidFileURL() -> URL { appSupportDir().appendingPathComponent("sp_aienergy_agent.pid") }

/// 确保只有一个 SP-AIEnergyAgent 实例运行；若已有实例则直接退出。
func ensureSingleInstance() -> Bool {
  let pidFile = pidFileURL()
  let myPID = ProcessInfo.processInfo.processIdentifier
  if let data = try? Data(contentsOf: pidFile),
     let s = String(data: data, encoding: .utf8),
     let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)),
     pid != myPID {
    if kill(pid, 0) == 0 {
      print("[SP-AIEnergyAgent] 已有实例 PID \(pid) 在运行，本实例退出。")
      return false
    }
  }
  try? "\(myPID)".write(to: pidFile, atomically: true, encoding: .utf8)
  return true
}

func removePIDFile() {
  try? FileManager.default.removeItem(at: pidFileURL())
}

/// 主面板 app 的 URL：本辅助可执行文件位于 <App>.app/Contents/MacOS/SP-AIEnergyAgent。
/// 若 macOS 已将 Bundle.main 识别为 .app 则直接返回，否则向上回退两级。
func mainAppURL() -> URL? {
  let bundleURL = Bundle.main.bundleURL
  if bundleURL.pathExtension == "app" { return bundleURL }
  let app = bundleURL.deletingLastPathComponent().deletingLastPathComponent()
  guard app.pathExtension == "app" else { return nil }
  return app
}

/// 应用 Resources 目录：用于从辅助可执行文件定位主 bundle 资源。
func appResourcesDir() -> URL {
  let bundleURL = Bundle.main.bundleURL
  if bundleURL.pathExtension == "app" {
    return bundleURL.appendingPathComponent("Contents/Resources")
  }
  return bundleURL.deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Contents/Resources")
}

// MARK: - 运行时配置

struct RuntimeConfig {
  var enabled = false
  var modelID = "Qwen2.5-1.5B-Instruct-4bit"
  var modelPath = ""
  var pythonExecutable = "/usr/bin/python3"
  var port = 8080
  var temperature = 0.1
  var maxTokens = 512
  var topP = 1.0
  var trayIconName = "MenuBarMouseTemplate"

  static func load() -> RuntimeConfig? {
    guard let data = try? Data(contentsOf: runtimeConfigURL()),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    var c = RuntimeConfig()
    c.enabled = (obj["enabled"] as? Bool) ?? false
    c.modelID = (obj["modelID"] as? String) ?? c.modelID
    c.modelPath = (obj["modelPath"] as? String) ?? ""
    c.pythonExecutable = (obj["pythonExecutable"] as? String) ?? c.pythonExecutable
    c.port = (obj["port"] as? Int) ?? 8080
    c.temperature = (obj["temperature"] as? Double) ?? 0.1
    c.maxTokens = (obj["maxTokens"] as? Int) ?? 512
    c.topP = (obj["topP"] as? Double) ?? 1.0
    c.trayIconName = (obj["trayIconName"] as? String) ?? "MenuBarMouseTemplate"
    return c
  }

  func write() {
    let dict: [String: Any] = [
      "enabled": enabled,
      "modelID": modelID,
      "modelPath": modelPath,
      "pythonExecutable": pythonExecutable,
      "port": port,
      "temperature": temperature,
      "maxTokens": maxTokens,
      "topP": topP,
      "trayIconName": trayIconName,
      "startupAtLogin": false,
      "updateCheckEnabled": false,
      "updateCheckIntervalDays": 1,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) else { return }
    try? data.write(to: runtimeConfigURL(), options: [.atomic])
  }
}

// MARK: - 状态写入

func writeStatus(running: Bool, message: String, error: String? = nil) {
  let dict: [String: Any] = [
    "running": running,
    "message": message,
    "error": error ?? "",
    "updated": ISO8601DateFormatter().string(from: Date()),
  ]
  guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
  try? data.write(to: statusURL())
}

// MARK: - 健康检查

/// 本地回环专用 URLSession：显式禁用代理。
/// 用户机器上常配有系统代理，若让回环请求走代理会被打成 502/超时，
/// 健康检查就会永远失败（面板一直显示「加载中」）。
let localSession: URLSession = {
  let cfg = URLSessionConfiguration.ephemeral
  cfg.connectionProxyDictionary = [:]
  cfg.timeoutIntervalForRequest = 3
  return URLSession(configuration: cfg)
}()

// MARK: - 进程管理

/// 子进程环境：清掉代理变量并把回环加入 no_proxy。
/// 子进程与本地服务之间全部走 127.0.0.1，若继承了用户的代理设置，
/// 请求会被发给代理，导致 502 或长时间超时。
func childEnvironment() -> [String: String] {
  var env = ProcessInfo.processInfo.environment
  for k in ["http_proxy", "https_proxy", "all_proxy",
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"] { env[k] = nil }
  env["no_proxy"] = "localhost,127.0.0.1,::1"
  env["NO_PROXY"] = "localhost,127.0.0.1,::1"
  env["PYTHONUNBUFFERED"] = "1"
  return env
}

/// 取得可写日志句柄并定位到末尾。
/// `FileHandle(forWritingTo:)` 要求文件已存在，否则返回 nil，子进程输出会被静默丢弃，
/// 排障时完全看不到 mlx / service 的报错。这里先确保文件存在。
func logHandle(_ name: String) -> FileHandle? {
  let url = appSupportDir().appendingPathComponent(name)
  if !FileManager.default.fileExists(atPath: url.path) {
    FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
  }
  guard let fh = try? FileHandle(forWritingTo: url) else { return nil }
  fh.seekToEndOfFile()
  return fh
}

/// 记录 mlx server / service 子进程 pid 的文件。
/// Agent 异常退出（崩溃、强杀、注销）时子进程会变成孤儿继续占住端口，
/// 下次启动 `terminateChildren()` 只认得本实例的 Process 对象，管不到它们，
/// 于是新 server 撞上 `Address already in use` 起不来，而旧的那个若加载失败
/// 又会让所有请求 hang 住——必须靠 pid 文件跨进程回收。
func childPIDFileURL(_ name: String) -> URL {
  appSupportDir().appendingPathComponent("aienergy_\(name).pid")
}

func recordChildPID(_ name: String, _ p: Process?) {
  guard let p, p.isRunning else { return }
  try? "\(p.processIdentifier)".write(to: childPIDFileURL(name), atomically: true, encoding: .utf8)
}

func terminateChildren() {
  // Phase 2: 终止 AI 联想层服务子进程（替换原 mlx / AIEnergy_service.py）。
  // 当前版本引擎未接入，留作占位。
}

/// 模型目录是否真的可用于推理：必须同时有 config.json 和权重文件。
/// 只判断目录存在是不够的——面板下载前会先 mkdir，空目录会让本地模型服务
/// 加载失败，从而无法提供推理。
func modelUsable(_ path: String) -> Bool {
  let fm = FileManager.default
  guard fm.fileExists(atPath: (path as NSString).appendingPathComponent("config.json")),
        let items = try? fm.contentsOfDirectory(atPath: path) else { return false }
  return items.contains { $0.hasSuffix(".safetensors") || $0.hasSuffix(".npz") }
}

// MARK: - 主应用委托

class AgentAppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem?
  private var config: RuntimeConfig?
  private var configWatcher: DispatchSourceFileSystemObject?
  private var heartbeatTimer: Timer?
  private var lastStartAttempt: Date?

  func applicationDidFinishLaunching(_ notification: Notification) {
    print("[SP-AIEnergyAgent] Bundle.main = \(Bundle.main.bundleURL.path)")
    NSApp.setActivationPolicy(.accessory)
    setupStatusItem()
    loadConfigAndApply()
    startConfigWatcher()
    registerDistributedObserver()
    startHeartbeat()
  }

  func applicationWillTerminate(_ notification: Notification) {
    stopHeartbeat()
    terminateChildren()
    writeStatus(running: false, message: "stopped")
    removePIDFile()
  }

  // 双击 .app / Dock 图标触发的 reopen 可能因为 bundle id 冲突被 Launch Services
  // 路由到 Agent（而非主面板）。这里统一转发给主面板，避免 reopen 事件丢失导致打不开面板。
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    openMainPanel()
    return true
  }

  // MARK: - 系统栏图标

  private func setupStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    print("[SP-AIEnergyAgent] statusItem = \(item)")
    if let button = item.button {
      updateIcon(button)
      print("[SP-AIEnergyAgent] button.image = \(String(describing: button.image)), size = \(button.image?.size ?? .zero)")
      button.action = #selector(statusItemClicked(_:))
      button.target = self
    } else {
      print("[SP-AIEnergyAgent] item.button is nil")
    }
    item.menu = buildContextMenu()
    item.isVisible = true
    item.behavior = []
    statusItem = item
    // accessory 应用创建的状态栏图标默认可能不可见，强制激活应用一次以确保图标出现
    NSApp.activate(ignoringOtherApps: true)
    fflush(stdout)
  }

  private func updateIcon(_ button: NSButton) {
    let name = config?.trayIconName ?? "MenuBarMouseTemplate"
    let image: NSImage? = loadTrayIcon(named: name)
    button.image = image
    button.imageScaling = .scaleProportionallyDown
  }

  private func loadTrayIcon(named name: String) -> NSImage? {
    let resources = appResourcesDir()
    let icon36 = resources.appendingPathComponent("TrayIcons/\(name)_36.png")
    if FileManager.default.fileExists(atPath: icon36.path),
       let img = NSImage(contentsOf: icon36) {
      // 系统栏图标统一按 26pt 渲染；36x36 资源足够 retina 清晰度。
      img.size = NSSize(width: 26, height: 26)
      // 所有图标均已处理为黑色透明模板图，统一按 template 渲染以随菜单栏自动反色。
      img.isTemplate = true
      return img
    }
    // 兜底：旧配置指向已删除图标时回到默认模板
    let fallback = resources.appendingPathComponent("MenuBarMouseTemplate.png")
    if FileManager.default.fileExists(atPath: fallback.path),
       let img = NSImage(contentsOf: fallback) {
      img.size = NSSize(width: 26, height: 26)
      img.isTemplate = true
      return img
    }
    return nil
  }

  @objc private func statusItemClicked(_ sender: Any?) {
    openMainPanel()
  }

  private func buildContextMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "打开鼠须管控制面板", action: #selector(menuOpenPanel), keyEquivalent: ""))
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "退出", action: #selector(menuQuit), keyEquivalent: ""))

    for item in menu.items { item.target = self }
    return menu
  }

  @objc private func menuOpenPanel() {
    openMainPanel()
  }

  @objc private func menuQuit() {
    terminateChildren()
    NSApp.terminate(nil)
  }

  private func openMainPanel() {
    // ⚠️ 关键修复：不能用 NSWorkspace.shared.open(app)。
    // SP-AIEnergyAgent 作为主 bundle 的辅助可执行文件，与主面板共享同一个
    // bundle id（io.github.wolfprince12.squirrel-panel）。一旦 Agent 进程运行，
    // Launch Services 会认为该 bundle「已在运行」，open(app) 只会激活 Agent
    // 自己（无窗口的 accessory），而不会唤起/启动主面板 —— 这就是「点了小老鼠
    // 打不开面板」的根因。这里改为两条绕开 Launch Services 的通道：
    // 1) 发分布式通知，唤醒「已在运行但窗口隐藏」的主面板；
    // 2) 主面板未运行则直接 spawn 主面板可执行文件。
    DistributedNotificationCenter.default().postNotificationName(
      .init("io.github.wolfprince12.squirrel-panel.openPanel"),
      object: nil,
      userInfo: nil,
      deliverImmediately: true
    )
    if !isMainPanelRunning() {
      spawnMainPanel()
    }
  }

  /// 主面板进程（可执行文件名 SquirrelPanel）是否在运行。
  /// 用 pgrep -x 精确匹配进程名，避免把 Agent 自己（SP-AIEnergyAgent）误判为主面板。
  private func isMainPanelRunning() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-x", "SquirrelPanel"]
    p.standardOutput = nil
    p.standardError = nil
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus == 0
  }

  /// 直接 spawn 主面板可执行文件，绕开 Launch Services 的 bundle id 检查。
  private func spawnMainPanel() {
    guard let app = mainAppURL() else { return }
    let exec = app.appendingPathComponent("Contents/MacOS/SquirrelPanel")
    let p = Process()
    p.executableURL = exec
    try? p.run()
  }

  // MARK: - 配置加载与应用

  private func loadConfigAndApply() {
    config = RuntimeConfig.load()
    if config == nil {
      writeStatus(running: false, message: "no config", error: "aienergy_config.json 缺失")
    }
    applyConfig()
  }

  private func applyConfig() {
    guard let cfg = config else { return }
    updateStatusIcon()

    if !cfg.enabled {
      terminateChildren()
      writeStatus(running: false, message: "disabled")
      return
    }

    // Phase 2: 启动 AI 联想层服务（替换原 mlx / AIEnergy_service.py）。
    // 当前版本仅保留常驻外壳，引擎实现待接入。
    startEngine(cfg)
  }

  private func updateStatusIcon() {
    guard let button = statusItem?.button else { return }
    updateIcon(button)
  }

  private func startEngine(_ cfg: RuntimeConfig) {
    // Phase 2: 启动 AI 联想层服务（替换原 mlx_lm server + AIEnergy_service.py）。
    // 当前版本引擎未接入，留作占位；状态由 heartbeat 在接入后维护。
    terminateChildren()
    print("[SP-AIEnergyAgent] 引擎待 Phase 2 接入：模型 \(cfg.modelID)")
  }

  // MARK: - 心跳与自愈

  private func startHeartbeat() {
    heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
      self?.heartbeat()
    }
  }

  private func stopHeartbeat() {
    heartbeatTimer?.invalidate()
    heartbeatTimer = nil
  }

  private func heartbeat() {
    // Phase 2: 自检 AI 联想层服务存活并自愈（替换原 mlx health 检查）。
    guard let cfg = config, cfg.enabled else { return }
    if let last = lastStartAttempt, Date().timeIntervalSince(last) < 10 { return }
  }

  // MARK: - 配置监听

  private func startConfigWatcher() {
    let url = runtimeConfigURL()
    let fd = open(url.path, O_EVTONLY)
    guard fd >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: DispatchQueue.main)
    source.setEventHandler { [weak self] in
      // 文件写入后可能还有短暂抖动，延迟 300ms 再读取
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
        self?.loadConfigAndApply()
      }
    }
    source.setCancelHandler { close(fd) }
    source.resume()
    configWatcher = source
  }

  private func registerDistributedObserver() {
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(configDidChangeExternally),
      name: .init("io.github.wolfprince12.squirrel-panel.aienergy.configChanged"),
      object: nil
    )
  }

  @objc private func configDidChangeExternally(_ notification: Notification) {
    loadConfigAndApply()
  }
}

// MARK: - 入口

// 单例检查必须在 NSApplication 启动前完成，避免重复进程竞争系统栏。
guard ensureSingleInstance() else { exit(0) }

let app = NSApplication.shared
let delegate = AgentAppDelegate()
app.delegate = delegate
app.run()

// 正常退出时清理 pid 文件
removePIDFile()
