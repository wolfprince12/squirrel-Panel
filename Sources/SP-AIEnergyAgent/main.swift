//
//  SP-AIEnergyAgent.swift
//  SP-AIEnergyAgent — Squirrel Panel 常驻托盘代理
//
//  长期驻留系统的独立后台进程，职责极简：
//  - 在系统栏显示小老鼠图标；
//  - 点击图标 / 右键菜单「打开面板」唤起主面板（鼠须管控制面板）；
//  - 双击 .app / Dock 图标时统一转发给已运行的主面板，避免 bundle id 冲突
//    导致 Launch Services 把事件误路由到本代理。
//
//  注：AI 纠错引擎（Python + MLX + 本地大模型 + 联想层）已于 2026-08 彻底下线，
//  其全部代码与资源已移除。本代理不再承担任何推理 / 模型 / 配置监听职责。
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

func pidFileURL() -> URL { appSupportDir().appendingPathComponent("sp_tray_agent.pid") }

/// 确保只有一个本代理实例运行；若已有实例则直接退出。
func ensureSingleInstance() -> Bool {
  let pidFile = pidFileURL()
  let myPID = ProcessInfo.processInfo.processIdentifier
  if let data = try? Data(contentsOf: pidFile),
     let s = String(data: data, encoding: .utf8),
     let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)),
     pid != myPID {
    if kill(pid, 0) == 0 {
      print("[SPTrayAgent] 已有实例 PID \(pid) 在运行，本实例退出。")
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

/// 应用 Resources 目录：用于从辅助可执行文件定位主 bundle 资源（托盘图标）。
func appResourcesDir() -> URL {
  let bundleURL = Bundle.main.bundleURL
  if bundleURL.pathExtension == "app" {
    return bundleURL.appendingPathComponent("Contents/Resources")
  }
  return bundleURL.deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Contents/Resources")
}

// MARK: - 托盘图标 + 面板唤起

class TrayAgentDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem?
  /// 固定的托盘图标名（不再提供切换：AI 引擎已下线，图标无关模型状态）。
  private let trayIconName = "MenuBarMouseTemplate"

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    setupStatusItem()
  }

  func applicationWillTerminate(_ notification: Notification) {
    removePIDFile()
  }

  // 双击 .app / Dock 图标触发的 reopen 可能因 bundle id 冲突被 Launch Services
  // 路由到本代理（而非主面板）。这里统一转发给主面板，避免 reopen 事件丢失打不开面板。
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    openMainPanel()
    return true
  }

  // MARK: - 系统栏图标

  private func setupStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      updateIcon(button)
      button.action = #selector(statusItemClicked(_:))
      button.target = self
    }
    item.menu = buildContextMenu()
    item.isVisible = true
    item.behavior = []
    statusItem = item
    NSApp.activate(ignoringOtherApps: true)
  }

  private func updateIcon(_ button: NSButton) {
    guard let img = loadTrayIcon(named: trayIconName) else { return }
    button.image = img
    button.imageScaling = .scaleProportionallyDown
  }

  private func loadTrayIcon(named name: String) -> NSImage? {
    let resources = appResourcesDir()
    let icon36 = resources.appendingPathComponent("TrayIcons/\(name)_36.png")
    if FileManager.default.fileExists(atPath: icon36.path),
       let img = NSImage(contentsOf: icon36) {
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
    NSApp.terminate(nil)
  }

  private func openMainPanel() {
    // ⚠️ 关键：不能用 NSWorkspace.shared.open(app)。
    // 本代理与主面板共享同一个 bundle id（io.github.wolfprince12.squirrel-panel）。
    // 一旦本代理运行，Launch Services 会认为该 bundle「已在运行」，open(app)
    // 只会激活代理自己（无窗口的 accessory），而不会唤起主面板。改为两条绕开
    // Launch Services 的通道：
    // 1) 发分布式通知，唤醒「已在运行但窗口隐藏」的主面板；
    // 2) 主面板未运行则直接 spawn 主面板可执行文件。
    DistributedNotificationCenter.default().postNotificationName(
      .init("io.github.wolfprince12.squirrel-panel.openPanel"),
      object: nil, userInfo: nil, deliverImmediately: true
    )
    if !isMainPanelRunning() {
      spawnMainPanel()
    }
  }

  /// 主面板进程（可执行文件名 SquirrelPanel）是否在运行。
  /// 用 pgrep -x 精确匹配进程名，避免把本代理（SP-AIEnergyAgent）误判为主面板。
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
}

// MARK: - 入口

// 单例检查必须在 NSApplication 启动前完成，避免重复进程竞争系统栏。
guard ensureSingleInstance() else { exit(0) }

let app = NSApplication.shared
let delegate = TrayAgentDelegate()
app.delegate = delegate
app.run()

// 正常退出时清理 pid 文件
removePIDFile()
