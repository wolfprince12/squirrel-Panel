//
//  SP-AIEnergyAgent.swift
//  SP-AIEnergyAgent — Squirrel Panel AI Energy Resident Agent
//
//  长期驻留系统的独立后台进程：
//  - 在系统栏显示小老鼠图标（可由用户切换图标）；
//  - 读取运行时配置，拉起并监管 mlx_lm server + AIEnergy_service.py；
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
  var apiURL = "http://localhost:8080/v1"
  var pythonExecutable = "/usr/bin/python3"
  var serviceScript = ""
  var port = 8080
  var temperature = 0.1
  var maxTokens = 512
  var topP = 1.0
  var correctionEnabled = true
  var translationHotkey = "ctrl+t"
  var dialogHotkey = "ctrl+d"
  var candidateIndex = 9
  var trayIconName = "MenuBarMouseTemplate"

  static func load() -> RuntimeConfig? {
    guard let data = try? Data(contentsOf: runtimeConfigURL()),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    var c = RuntimeConfig()
    c.enabled = (obj["enabled"] as? Bool) ?? false
    c.modelID = (obj["modelID"] as? String) ?? c.modelID
    c.modelPath = (obj["modelPath"] as? String) ?? ""
    c.apiURL = (obj["apiURL"] as? String) ?? c.apiURL
    c.pythonExecutable = (obj["pythonExecutable"] as? String) ?? c.pythonExecutable
    c.serviceScript = (obj["serviceScript"] as? String) ?? ""
    c.port = (obj["port"] as? Int) ?? 8080
    c.temperature = (obj["temperature"] as? Double) ?? 0.1
    c.maxTokens = (obj["maxTokens"] as? Int) ?? 512
    c.topP = (obj["topP"] as? Double) ?? 1.0
    c.correctionEnabled = (obj["correctionEnabled"] as? Bool) ?? true
    c.translationHotkey = (obj["translationHotkey"] as? String) ?? "cmd+f"
    c.dialogHotkey = (obj["dialogHotkey"] as? String) ?? "ctrl+t"
    c.candidateIndex = (obj["candidateIndex"] as? Int) ?? 1
    c.trayIconName = (obj["trayIconName"] as? String) ?? "MenuBarMouseTemplate"
    return c
  }

  func write() {
    let dict: [String: Any] = [
      "enabled": enabled,
      "modelID": modelID,
      "modelPath": modelPath,
      "apiURL": apiURL,
      "pythonExecutable": pythonExecutable,
      "serviceScript": serviceScript,
      "port": port,
      "temperature": temperature,
      "maxTokens": maxTokens,
      "topP": topP,
      "correctionEnabled": correctionEnabled,
      "translationHotkey": translationHotkey,
      "dialogHotkey": dialogHotkey,
      "candidateIndex": candidateIndex,
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

func mlxHealthy(port: Int) -> Bool {
  guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
  var req = URLRequest(url: url, timeoutInterval: 2)
  req.httpMethod = "GET"
  let sem = DispatchSemaphore(value: 0)
  var ok = false
  let task = localSession.dataTask(with: req) { _, resp, _ in
    ok = (resp as? HTTPURLResponse)?.statusCode == 200
    sem.signal()
  }
  task.resume()
  sem.wait()
  return ok
}

// MARK: - 进程管理

var mlxTask: Process?
var serviceTask: Process?

/// 子进程环境：清掉代理变量并把回环加入 no_proxy。
/// mlx server 与 Python 服务之间全部走 127.0.0.1，若继承了用户的代理设置，
/// requests / httpx 会把本地请求也发给代理，导致 502 或长时间超时。
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

/// 找到正 LISTEN 在指定 TCP 端口上的进程 PID。
private func pidsListening(on port: Int) -> [Int32] {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
  p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
  let pipe = Pipe()
  p.standardOutput = pipe
  p.standardError = nil
  try? p.run(); p.waitUntilExit()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  guard let s = String(data: data, encoding: .utf8) else { return [] }
  return s.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
}

/// 判断某 PID 是否像我们的 mlx server（命令含 `mlx_lm server`）。
private func isMLXServerProcess(_ pid: Int32) -> Bool {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/bin/ps")
  p.arguments = ["-o", "command=", "-p", "\(pid)"]
  let pipe = Pipe()
  p.standardOutput = pipe
  p.standardError = nil
  try? p.run(); p.waitUntilExit()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  guard let s = String(data: data, encoding: .utf8) else { return false }
  return s.contains("mlx_lm") && s.contains("server")
}

/// 找到所有命令行包含指定子串的进程 PID（用 pgrep -f）。
/// 用于回收「不监听端口、也不含 mlx 字样」的 AIEnergy_service.py 孤儿进程——
/// 这类进程既不会被按端口回收（它不 LISTEN），也不满足 isMLXServerProcess，
/// 只能按命令名精确匹配。
private func pidsMatching(command substring: String) -> [Int32] {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
  p.arguments = ["-f", substring]
  let pipe = Pipe()
  p.standardOutput = pipe
  p.standardError = nil
  try? p.run(); p.waitUntilExit()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  guard let s = String(data: data, encoding: .utf8) else { return [] }
  return s.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
}

/// 回收上一次遗留的孤儿子进程：
/// 1) pid 文件里记录过的、确实是我们启动的进程（崩溃/强杀后 pid 文件还在的情况）；
/// 2) 端口占用者——对于更早版本启动、pid 文件已丢失的孤儿（例如上次测试遗留的 mlx
///    server），pid 文件机制管不到，必须按端口回收，否则新 server 永远撞
///    `Address already in use`，而旧 server 若加载失败又会让所有请求 hang 住。
/// 按端口只杀「确为我们的 mlx server」的进程，避免误杀用户其它 8080 服务。
func reapOrphanChildren(port: Int) {
  for name in ["mlx", "service"] {
    let f = childPIDFileURL(name)
    defer { try? FileManager.default.removeItem(at: f) }
    guard let s = try? String(contentsOf: f, encoding: .utf8),
          let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)),
          pid > 1, pid != ProcessInfo.processInfo.processIdentifier,
          kill(pid, 0) == 0 else { continue }
    print("[SP-AIEnergyAgent] 回收遗留 \(name) 进程 PID \(pid)")
    kill(pid, SIGTERM)
  }
  let mine = [mlxTask?.processIdentifier, serviceTask?.processIdentifier].compactMap { $0 }
  let me = ProcessInfo.processInfo.processIdentifier
  for pid in pidsListening(on: port) {
    if pid == me || mine.contains(pid) { continue }
    if isMLXServerProcess(pid) {
      print("[SP-AIEnergyAgent] 回收端口 \(port) 占用者 PID \(pid)")
      kill(pid, SIGTERM)
    }
  }
  // 回收所有 AIEnergy_service.py 孤儿进程：它不 LISTEN 8080、也不含 mlx 字样，
  // 前面按端口/按 mlx 两路都覆盖不到，必须按命令名精确回收，否则反复启停引擎会
  // 泄漏出一大批 service 进程，拖垮资源并导致主面板无法唤起。
  for pid in pidsMatching(command: "AIEnergy_service.py") {
    if pid == me || mine.contains(pid) { continue }
    print("[SP-AIEnergyAgent] 回收遗留 service 进程 PID \(pid)")
    kill(pid, SIGTERM)
  }
}

func terminateChildren() {
  serviceTask?.terminate()
  mlxTask?.terminate()
  serviceTask = nil
  mlxTask = nil
  let me = ProcessInfo.processInfo.processIdentifier
  // 按 pid 文件回收 mlx / service：本实例的 Process 对象可能已失效（如 Agent
  // 重启、ensureSingleInstance 空壳），pid 文件才是跨实例可靠的回收依据。
  // 之前只 removeItem 不 kill，导致 Agent 退出后 mlx server 变孤儿残留。
  for name in ["mlx", "service"] {
    let f = childPIDFileURL(name)
    if let s = try? String(contentsOf: f, encoding: .utf8),
       let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)),
       pid > 1, pid != me, kill(pid, 0) == 0 {
      print("[SP-AIEnergyAgent] 终止 \(name) 进程 PID \(pid)")
      kill(pid, SIGTERM)
    }
    try? FileManager.default.removeItem(at: f)
  }
  // 按命令名回收所有 AIEnergy_service.py 孤儿：pid 文件只记录最后一次启动的 PID，
  // 历史泄漏（heartbeat 反复重启、Agent 被强杀）覆盖不到，必须全量回收。
  for pid in pidsMatching(command: "AIEnergy_service.py") {
    if pid == me { continue }
    kill(pid, SIGTERM)
  }
}

/// 模型目录是否真的可用于推理：必须同时有 config.json 和权重文件。
/// 只判断目录存在是不够的——面板下载前会先 mkdir，空目录会让 mlx_lm server
/// 加载失败却仍占住端口监听，此后所有请求都 hang 住。
func modelUsable(_ path: String) -> Bool {
  let fm = FileManager.default
  guard fm.fileExists(atPath: (path as NSString).appendingPathComponent("config.json")),
        let items = try? fm.contentsOfDirectory(atPath: path) else { return false }
  return items.contains { $0.hasSuffix(".safetensors") || $0.hasSuffix(".npz") }
}

func launchMLX(_ cfg: RuntimeConfig) -> Process? {
  guard modelUsable(cfg.modelPath) else { return nil }
  let p = Process()
  p.executableURL = URL(fileURLWithPath: cfg.pythonExecutable)
  p.arguments = ["-m", "mlx_lm", "server", "--model", cfg.modelPath, "--port", "\(cfg.port)"]
  p.environment = childEnvironment()
  p.standardOutput = logHandle("aienergy_mlx.log")
  p.standardError = p.standardOutput
  try? p.run()
  return p
}

func launchService(_ cfg: RuntimeConfig) -> Process? {
  guard !cfg.serviceScript.isEmpty, FileManager.default.fileExists(atPath: cfg.serviceScript) else { return nil }
  let bzxConfigURL = appSupportDir().appendingPathComponent("aienergy_service_config.json")
  let bzx: [String: Any] = [
    "engine": [
      "api_url": "\(cfg.apiURL)/chat/completions",
      "api_key": "",
      // 必须是 mlx_lm server 启动时 --model 的同一个「完整本地路径」。
      // 实测：传短名（如 Qwen2.5-1.5B-Instruct-4bit）时 server 会把它当 HuggingFace
      // repo 去联网拉取，返回 404 且每次请求白等 ~13s；传完整路径则 200 且 ~2s。
      "model": cfg.modelPath,
      "temperature": cfg.temperature,
      "max_tokens": cfg.maxTokens,
      "top_p": cfg.topP,
    ],
    "trigger": [
      // 纠错已改为「停顿触发（防抖 450ms）」，不再 per_key；且此字段 service.py 不消费，
      // 仅保留语义正确的值。纠错是否启用由 AI 增强总开关决定，无独立关闭。
      "correction": "auto",
      "translation_hotkey": cfg.translationHotkey,
      "dialog_hotkey": cfg.dialogHotkey,
      "candidate_index": cfg.candidateIndex,
    ],
  ]
  if let data = try? JSONSerialization.data(withJSONObject: bzx, options: .prettyPrinted) {
    try? data.write(to: bzxConfigURL)
  }
  let p = Process()
  p.executableURL = URL(fileURLWithPath: cfg.pythonExecutable)
  p.arguments = [cfg.serviceScript, "--config", bzxConfigURL.path]
  p.environment = childEnvironment()
  p.standardOutput = logHandle("aienergy_service.log")
  p.standardError = p.standardOutput
  try? p.run()
  return p
}

func mlxAvailable(_ cfg: RuntimeConfig) -> Bool {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: cfg.pythonExecutable)
  p.arguments = ["-c", "import mlx_lm"]
  p.standardOutput = nil
  p.standardError = nil
  do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
  catch { return false }
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

    guard mlxAvailable(cfg) else {
      terminateChildren()
      writeStatus(running: false, message: "mlx_missing", error: "Python 未安装 mlx-lm，无法运行本地模型")
      return
    }

    startEngine(cfg)
  }

  private func updateStatusIcon() {
    guard let button = statusItem?.button else { return }
    updateIcon(button)
  }

  private func startEngine(_ cfg: RuntimeConfig) {
    terminateChildren()
    // 先回收上次遗留的孤儿子进程（含按端口回收的旧 mlx server），否则新 mlx server
    // 会撞上端口占用起不来，导致 AI 完全无响应。
    reapOrphanChildren(port: cfg.port)
    lastStartAttempt = Date()
    print("[SP-AIEnergyAgent] 启动引擎，模型: \(cfg.modelID)")

    guard modelUsable(cfg.modelPath) else {
      writeStatus(running: false, message: "model_missing",
                  error: "模型权重不完整，请在「大模型商店」重新下载")
      return
    }

    mlxTask = launchMLX(cfg)
    serviceTask = launchService(cfg)
    recordChildPID("mlx", mlxTask)
    recordChildPID("service", serviceTask)
    writeStatus(running: false, message: "starting…")
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
    guard let cfg = config, cfg.enabled else { return }
    if let last = lastStartAttempt, Date().timeIntervalSince(last) < 10 { return }

    if let mlx = mlxTask, !mlx.isRunning {
      mlxTask = launchMLX(cfg)
      recordChildPID("mlx", mlxTask)
    }
    if let svc = serviceTask, !svc.isRunning {
      serviceTask = launchService(cfg)
      recordChildPID("service", serviceTask)
    }

    let healthy = mlxHealthy(port: cfg.port)
    if healthy {
      writeStatus(running: true, message: "running")
    } else {
      writeStatus(running: false, message: "loading_model", error: "mlx 尚未就绪，正在加载权重…")
    }
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
