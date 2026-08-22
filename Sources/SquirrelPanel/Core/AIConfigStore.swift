//
//  AIConfigStore.swift
//  Squirrel Panel
//
//  AI 增强引擎面板的配置与常驻引擎控制。
//  配置持久化到 UserDefaults（与 Rime 补丁完全隔离）；
//  运行时把引擎需要的参数写成 JSON，由 SP-AIEnergyAgent 常驻进程监管。
//

import Foundation
import SwiftUI

enum AIError: LocalizedError {
  case pythonMissing
  case agentStartFailed(String)

  var errorDescription: String? {
    switch self {
    case .pythonMissing: return String(localized: "ai.error.pythonMissing")
    case .agentStartFailed(let m): return String(localized: "ai.error.agentStart") + m
    }
  }
}

@MainActor
@Observable
final class AIConfigStore {
  // MARK: - 持久化键
  private enum Keys {
    static let engineEnabled = "AI.engineEnabled"
    static let modelID = "AI.modelID"
    static let pythonExecutable = "AI.pythonExecutable"
    static let temperature = "AI.temperature"
    static let maxTokens = "AI.maxTokens"
    static let topP = "AI.topP"
    static let startupAtLogin = "AI.startupAtLogin"
    static let updateCheckEnabled = "AI.updateCheckEnabled"
    static let updateCheckIntervalDays = "AI.updateCheckIntervalDays"
    static let trayIconName = "AI.trayIconName"
    static let githubToken = "AI.githubToken"
  }

  /// 通用 GitHub API User-Agent（GitHub 拒绝无 UA 请求）
  static let githubUserAgent = "Squirrel-Panel/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0")"

  /// GitHub API 请求头注入（User-Agent 必填；token 可选，配置后速率限制 5000/h）
  static func githubHeaders(token: String? = nil) -> [String: String] {
    var h = [
      "Accept": "application/vnd.github+json",
      "User-Agent": githubUserAgent,
      "X-GitHub-Api-Version": "2022-11-28",
    ]
    if let t = token?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
      h["Authorization"] = "Bearer \(t)"
    }
    return h
  }

  // MARK: - 运行时状态（不持久化）
  var engineRunning = false
  var engineStatusMessage: String = "--"
  var pythonValid: Bool?
  var pythonVersion: String = ""
  var lastError: String?
  /// Python 运行依赖缺失（Agent 回报）：面板据此在开关区呈现「点击安装运行依赖」引导，
  /// 而非把「启动不了」当作致命错误。
  var pythonDependencyMissing: Bool = false
  private var engineProcess: Process?
  private var watchdogTimer: Timer?
  private var lastStartAttempt: Date?

  // MARK: - 可配置项
  var engineEnabled: Bool {
    didSet {
      guard oldValue != engineEnabled else { return }
      UserDefaults.standard.set(engineEnabled, forKey: Keys.engineEnabled)
      guard !isApplying else { return }
      // 「开机自启动」整合到「AI 增强功能开启」：两者同步开关。
      if startupAtLogin != engineEnabled {
        startupAtLogin = engineEnabled
      }
      if engineEnabled {
        // 直接启动常驻 Agent；Python 运行依赖缺失时由 Agent 回报「运行依赖缺失」状态，
        // 面板据此引导用户一键安装，而非在此致命拦截导致「启动不了」。
        validatePython()
        startEngine()
      } else {
        stopEngine()
      }
      writeRuntimeConfig(rimeDir: RimeEnvironment.userDirectory)
      // 通知常驻进程立即刷新配置
      notifyAgentConfigChanged()

      // 拼音纠错：同步开关到 Rime 的 speller/algebra（面板托管 rime_ice.custom.yaml），
      // 并即时部署，使 Squirrel 立即开始/停止按错键自动纠正。
      if let ice = AppServices.shared.iceStore {
        ice.correctionEnabled = engineEnabled
        try? ice.writePatch()
        if engineEnabled, RimeEnvironment.detect().isInstalled {
          try? SquirrelBridge.deploy(environment: RimeEnvironment.detect())
        }
      }
    }
  }
  var modelID: String {
    didSet {
      UserDefaults.standard.set(modelID, forKey: Keys.modelID)
      guard !isApplying else { return }
      writeRuntimeConfig(rimeDir: RimeEnvironment.userDirectory)
    }
  }
  var pythonExecutable: String {
    didSet {
      UserDefaults.standard.set(pythonExecutable, forKey: Keys.pythonExecutable)
      guard !isApplying else { return }
      validatePython()
      writeRuntimeConfig(rimeDir: RimeEnvironment.userDirectory)
    }
  }
  /// 采样温度
  var temperature: Double {
    didSet {
      UserDefaults.standard.set(temperature, forKey: Keys.temperature)
      guard !isApplying else { return }
      writeRuntimeConfig(rimeDir: RimeEnvironment.userDirectory)
    }
  }
  /// 最大生成长度
  var maxTokens: Int {
    didSet {
      UserDefaults.standard.set(maxTokens, forKey: Keys.maxTokens)
      guard !isApplying else { return }
      writeRuntimeConfig(rimeDir: RimeEnvironment.userDirectory)
    }
  }
  /// 核采样 top_p
  var topP: Double {
    didSet {
      UserDefaults.standard.set(topP, forKey: Keys.topP)
      guard !isApplying else { return }
      writeRuntimeConfig(rimeDir: RimeEnvironment.userDirectory)
    }
  }
  /// 开机自启动（小老鼠登录即驻留）
  var startupAtLogin: Bool {
    didSet {
      guard oldValue != startupAtLogin else { return }
      UserDefaults.standard.set(startupAtLogin, forKey: Keys.startupAtLogin)
      guard !isApplying else { return }
      setLoginItemAsync(enabled: startupAtLogin)
    }
  }
  /// 每日自检更新
  var updateCheckEnabled: Bool {
    didSet { UserDefaults.standard.set(updateCheckEnabled, forKey: Keys.updateCheckEnabled) }
  }
  /// 自检间隔（天）
  var updateCheckIntervalDays: Int {
    didSet { UserDefaults.standard.set(max(1, updateCheckIntervalDays), forKey: Keys.updateCheckIntervalDays) }
  }
  /// 系统栏驻留图标名
  var trayIconName: String {
    didSet {
      UserDefaults.standard.set(trayIconName, forKey: Keys.trayIconName)
      guard !isApplying else { return }
      writeRuntimeConfig(rimeDir: RimeEnvironment.userDirectory)
      notifyAgentConfigChanged()
    }
  }
  /// GitHub Personal Access Token（可选，配置后 GitHub API 速率限制提升到 5000/h）
  var githubToken: String {
    didSet { UserDefaults.standard.set(githubToken, forKey: Keys.githubToken) }
  }

  // MARK: - 待应用配置（AI 增强引擎页统一走「应用并重新部署」）

  struct Pending {
    var modelID: String
    var temperature: Double
    var maxTokens: Int
    var topP: Double
    var trayIconName: String
    var githubToken: String
  }

  /// 用户当前在 UI 中修改但未提交的草案值。绑定到 AI 增强引擎页的所有配置控件。
  var pending: Pending

  /// 是否在批量提交 pending 值；为 true 时 didSet 只写 UserDefaults，不触发单条配置的副作用，
  /// 避免「应用」时每个属性都各自写盘/部署一次。
  private var isApplying = false

  var hasPendingChanges: Bool {
    pending.modelID != modelID
    || pending.temperature != temperature
    || pending.maxTokens != maxTokens
    || pending.topP != topP
    || pending.trayIconName != trayIconName
    || pending.githubToken != githubToken
  }

  /// 放弃未应用的改动，将草案恢复为当前已保存值。
  func discardPendingChanges() {
    pending = Pending(
      modelID: modelID,
      temperature: temperature,
      maxTokens: maxTokens,
      topP: topP,
      trayIconName: trayIconName,
      githubToken: githubToken
    )
  }

  /// 将 pending 中的改动一次性提交：写 UserDefaults、生成运行时配置。
  /// 引擎开关已独立即时生效，不在这里处理。
  /// 不触发 Rime 部署；调用方（SettingsStore.apply）负责统一部署，避免重复 deploy。
  func applyPendingChanges() {
    isApplying = true
    modelID = pending.modelID
    temperature = pending.temperature
    maxTokens = pending.maxTokens
    topP = pending.topP
    trayIconName = pending.trayIconName
    githubToken = pending.githubToken
    isApplying = false

    // 统一写一次运行时配置（含 lua 配置）并通知 Agent 刷新。
    writeRuntimeConfig(rimeDir: RimeEnvironment.userDirectory)
    notifyAgentConfigChanged()
  }

  /// 兼容入口：单独应用 AI 配置并立即部署。
  func applyPendingAndDeploy() {
    applyPendingChanges()
    try? SquirrelBridge.deploy(environment: RimeEnvironment.detect())
  }

  /// 供 SettingsStore 统一权限检查使用（AI 配置写 UserDefaults 与用户目录，始终可写）。
  var canWrite: Bool { true }

  /// 内置可选的系统栏图标
  static let trayIconOptions = [
    "MenuBarMouseTemplate",
    "tray_mouse_head",
    "tray_ai",
    "tray_mouse_chinese",
    "tray_wolf",
  ]

  static let defaultModelID = "Qwen2.5-1.5B-Instruct-4bit"

  // MARK: - 路径

  nonisolated static var appSupportDir: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appending(path: "SquirrelPanel", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  // MARK: - AI 运行时根目录（统一放在鼠须管输入法用户目录下）

  /// AI 全部运行时产物（Python 运行时 / 大模型 / 服务脚本）的统根目录：
  /// <Rime 用户目录>/aienergy/。这样 Python、模型、服务脚本都同居一处，
  /// 且跨 App 重装仍在；也符合用户「下载到鼠须管输入法目录下」的诉求。
  nonisolated static var runtimeHomeDir: URL {
    let dir = RimeEnvironment.userDirectory.appending(path: "aienergy", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// 解压后的 Python 运行时：<runtimeHome>/python/bin/python3
  nonisolated static var pythonRuntimeDir: URL {
    runtimeHomeDir.appending(path: "python", directoryHint: .isDirectory)
  }

  /// 按需下载解压后的 Python 解释器路径（存在才返回）。
  nonisolated static func runtimePythonPath() -> String? {
    let p = pythonRuntimeDir.appending(path: "bin/python3")
    return FileManager.default.fileExists(atPath: p.path) ? p.path : nil
  }

  /// 已安装 Python 运行时的发布 tag（写入 runtimeHome/python-runtime-tag.txt）。
  nonisolated static func installedPythonTag() -> String? {
    let f = runtimeHomeDir.appending(path: "python-runtime-tag.txt")
    guard let s = try? String(contentsOf: f, encoding: .utf8) else { return nil }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  nonisolated static var modelsDir: URL {
    let dir = runtimeHomeDir.appending(path: "models", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  var runtimeConfigURL: URL { Self.appSupportDir.appendingPathComponent("aienergy_config.json") }
  var rimeConfigURL: URL { RimeEnvironment.userDirectory.appendingPathComponent("AIEnergy_config.json") }
  var statusFileURL: URL { Self.appSupportDir.appendingPathComponent("aienergy_status.json") }

  private var loginItemLabel: String { "io.github.wolfprince12.sp-aienergy-agent.login" }
  private var loginItemPlistURL: URL {
    let dir = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("\(loginItemLabel).plist")
  }

  /// SP-AIEnergyAgent 辅助可执行文件路径（随 app 一起分发）。
  nonisolated static var agentExecutableURL: URL? {
    Bundle.main.url(forAuxiliaryExecutable: "SP-AIEnergyAgent")
      ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/SP-AIEnergyAgent")
  }

  // MARK: - 初始化

  init() {
    let ud = UserDefaults.standard
    let initialEngineEnabled = ud.bool(forKey: Keys.engineEnabled)
    let initialModelID = ud.string(forKey: Keys.modelID) ?? Self.defaultModelID
    let savedPy = ud.string(forKey: Keys.pythonExecutable)
    let initialPythonExecutable = (savedPy != nil && FileManager.default.fileExists(atPath: savedPy!))
      ? savedPy! : Self.detectPython()
    let initialTemperature = ud.object(forKey: Keys.temperature) as? Double ?? 0.1
    let initialMaxTokens = ud.object(forKey: Keys.maxTokens) as? Int ?? 512
    let initialTopP = ud.object(forKey: Keys.topP) as? Double ?? 1.0
    let initialStartupAtLogin = ud.bool(forKey: Keys.startupAtLogin)
    let initialUpdateCheckEnabled = ud.object(forKey: Keys.updateCheckEnabled) as? Bool ?? true
    let initialUpdateCheckIntervalDays = ud.object(forKey: Keys.updateCheckIntervalDays) as? Int ?? 1
    let initialTrayIconName = ud.string(forKey: Keys.trayIconName) ?? AIConfigStore.trayIconOptions[0]
    let initialGitHubToken = ud.string(forKey: Keys.githubToken) ?? ""

    self.engineEnabled = initialEngineEnabled
    self.modelID = initialModelID
    self.pythonExecutable = initialPythonExecutable
    self.temperature = initialTemperature
    self.maxTokens = initialMaxTokens
    self.topP = initialTopP
    self.startupAtLogin = initialStartupAtLogin
    self.updateCheckEnabled = initialUpdateCheckEnabled
    self.updateCheckIntervalDays = initialUpdateCheckIntervalDays
    self.trayIconName = initialTrayIconName
    self.githubToken = initialGitHubToken

    self.pending = Pending(
      modelID: initialModelID,
      temperature: initialTemperature,
      maxTokens: initialMaxTokens,
      topP: initialTopP,
      trayIconName: initialTrayIconName,
      githubToken: initialGitHubToken
    )

    validatePython()
    refreshStatus()

    // 首次启动即写入运行时配置，避免「aienergy_config.json 缺失」状态闪显
    writeRuntimeConfig(rimeDir: RimeEnvironment.userDirectory)

    // 如果引擎已开启且常驻进程尚未运行，则拉起 SP-AIEnergyAgent；
    // 若已通过开机自启动运行，则仅读取状态，避免重复启动多个实例。
    if engineEnabled, !engineRunning {
      startEngine()
    }

    // 「开机自启动」与「AI 增强功能开启」保持同步：
    // 必须在所有属性初始赋值完成后执行，避免 init 中的 didSet 被后续赋值覆盖。
    if startupAtLogin != engineEnabled {
      startupAtLogin = engineEnabled
    }
  }

  // MARK: - Python 检测

  /// 优先使用「按需下载到 Rime 用户目录」的 Python 运行时；否则回退到系统常见 python
  /// 中已存在的解释器（便于本机已有环境直接测试）；都没有则返回 /usr/bin/python3。
  static func detectPython() -> String {
    if let runtime = runtimePythonPath() {
      return runtime
    }
    let candidates = [
      "/opt/homebrew/bin/python3",
      "/opt/homebrew/bin/python3.12",
      "/usr/local/bin/python3",
      "/usr/bin/python3",
    ]
    // 返回首个存在的解释器
    for c in candidates where FileManager.default.fileExists(atPath: c) {
      return c
    }
    return "/usr/bin/python3"
  }

  /// 校验当前 python 是否可运行，并回填版本
  func validatePython() {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: pythonExecutable)
    proc.arguments = ["-c", "import sys; print('OK', sys.version)"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    do {
      try proc.run()
      proc.waitUntilExit()
      if proc.terminationStatus == 0,
         let data = try? pipe.fileHandleForReading.readToEnd(),
         let out = String(data: data, encoding: .utf8) {
        pythonValid = true
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        pythonVersion = trimmed.replacingOccurrences(of: "OK ", with: "")
      } else {
        pythonValid = false
        pythonVersion = ""
      }
    } catch {
      pythonValid = false
      pythonVersion = ""
    }
  }

  // MARK: - Python 运行时（按需从 GitHub Releases 下载，不再内置进 App）

  /// 随 GitHub Releases 分发的 Python 运行时资产名正则，例如
  /// aienergy-python-macos-arm64-1.0.tar.gz（其顶层目录应为 python/）。
  private static let pythonAssetPattern = #"aienergy-python-.*\.tar\.gz$"#
  static let pythonRepoOwner = "wolfprince12"
  static let pythonRepoName = "squirrel-Panel-aienergy-runtime"

  enum PythonRuntimeState: Equatable {
    case idle
    case checking
    case downloading
    case extracting
    case done
    case failed(String)
  }

  /// 已安装的 Python 运行时？（解压出 python/bin/python3 即视为就绪）
  var pythonRuntimeInstalled: Bool { Self.runtimePythonPath() != nil }
  var pythonRuntimeState: PythonRuntimeState = .idle
  /// 远端有更新的 Python 运行时发布（仅在已安装时才有意义）
  var pythonUpdateAvailable: Bool = false

  private struct GitHubRelease: Decodable {
    let tag_name: String
    let assets: [GitHubAsset]
  }
  private struct GitHubAsset: Decodable {
    let name: String
    let browser_download_url: String
  }

  /// 检查远端是否有更新的 Python 运行时发布
  func checkPythonUpdate() {
    Task { @MainActor in
      guard self.pythonRuntimeInstalled else {
        self.pythonUpdateAvailable = false
        return
      }
      self.pythonRuntimeState = .checking
      let (tag, _, error) = await fetchLatestPythonRelease()
      guard let tag else {
        self.pythonRuntimeState = .failed(error ?? String(localized: "ai.python.downloadFailed"))
        return
      }
      let installed = Self.installedPythonTag()
      let hasUpdate = (installed != nil) && (installed != tag)
      self.pythonUpdateAvailable = hasUpdate
      self.pythonRuntimeState = hasUpdate ? .idle : .done
    }
  }

  /// 安装或更新 Python 运行时（拉取 latest release 匹配资产并解压到 runtimeHome/python）
  func installOrUpdatePython() {
    // 立刻进入「下载中」状态，按钮转 spinner + 状态文字可见
    self.pythonRuntimeState = .downloading
    Task { @MainActor in
      let (tag, url, error) = await fetchLatestPythonRelease()
      if let error {
        self.pythonRuntimeState = .failed(
          String(localized: "ai.python.downloadFailed") + "：" + error
        )
        return
      }
      guard let tag, let url else {
        self.pythonRuntimeState = .failed(
          String(localized: "ai.python.downloadFailed") + "：未知错误"
        )
        return
      }
      self.downloadPython(from: url, tag: tag)
    }
  }

  private func downloadPython(from url: URL, tag: String) {
    let tmp = FileManager.default.temporaryDirectory
      .appending(path: "aienergy-python-\(tag).tar.gz")
    Task { @MainActor in
      do {
        // 走镜像 fallback 下载：原始 URL + 多个 ghproxy 镜像，任一成功即返回
        try await GitHubMirrorFetch.download(from: url.absoluteString, to: tmp, timeout: 120)
        self.pythonRuntimeState = .extracting
        self.extractPython(at: tmp, tag: tag)
      } catch let err as GitHubMirrorFetchError {
        self.pythonRuntimeState = .failed(err.errorDescription ?? String(localized: "ai.python.downloadFailed"))
      } catch {
        self.pythonRuntimeState = .failed(error.localizedDescription)
      }
    }
  }

  private func extractPython(at tarball: URL, tag: String) {
    let pyDir = Self.pythonRuntimeDir
    try? FileManager.default.removeItem(at: pyDir)
    try? FileManager.default.createDirectory(at: pyDir, withIntermediateDirectories: true)
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    proc.arguments = ["-xzf", tarball.path, "-C", pyDir.path]
    proc.standardError = Pipe()
    do {
      try proc.run(); proc.waitUntilExit()
      if proc.terminationStatus == 0, let py = Self.runtimePythonPath() {
        try? tag.write(to: Self.runtimeHomeDir.appending(path: "python-runtime-tag.txt"),
                       atomically: true, encoding: .utf8)
        pythonExecutable = py
        validatePython()
        Task { @MainActor in
          self.pythonRuntimeState = .done
          self.pythonUpdateAvailable = false
        }
      } else {
        Task { @MainActor in
          self.pythonRuntimeState = .failed(String(localized: "ai.python.extractBad"))
        }
      }
    } catch {
      Task { @MainActor in self.pythonRuntimeState = .failed(error.localizedDescription) }
    }
  }

  /// 卸载 Python 运行时（仅删除 runtimeHome/python，不影响其它数据）
  func removePythonRuntime() {
    // 先停掉引擎：否则常驻子进程仍持有已被删除的 Python 解释器，状态错乱。
    stopEngine()
    try? FileManager.default.removeItem(at: Self.pythonRuntimeDir)
    try? FileManager.default.removeItem(at: Self.runtimeHomeDir.appending(path: "python-runtime-tag.txt"))
    pythonUpdateAvailable = false
    pythonRuntimeState = .idle
    pythonExecutable = Self.detectPython()
    validatePython()
  }

  /// 拉取 latest release；返回 (tag, url)；失败时 error 不为 nil
  private func fetchLatestPythonRelease() async -> (tag: String?, url: URL?, error: String?) {
    // 1) 走 GitHubMirrorFetch：HEAD releases/latest 镜像优先 → API 镜像优先 → GET releases 镜像优先
    //    完全避开 GitHub API 的 60/h 限流（共享 IP 用户经常被卡）。
    let repo = "\(Self.pythonRepoOwner)/\(Self.pythonRepoName)"
    do {
      let result = try await GitHubMirrorFetch.fetchLatestRelease(repo: repo)
      // 已知资产名（仓库仅发一份 macOS arm64 包）；tag 拿到后直接拼 release/download 路径
      let assetName = "aienergy-python-macos-arm64.tar.gz"
      let assetURL = "https://github.com/\(repo)/releases/download/\(result.tag)/\(assetName)"
      guard let url = URL(string: assetURL) else {
        return (nil, nil, "资产 URL 解析失败")
      }
      return (result.tag, url, nil)
    } catch let err as GitHubMirrorFetchError {
      // 2) 镜像全部失败时的兜底：用户配置了 GitHub Token 则带 Token 直连 GitHub API 解析资产
      if !githubToken.isEmpty {
        return await fetchLatestPythonReleaseDirectViaToken()
      }
      return (nil, nil, err.errorDescription ?? String(localized: "ai.python.downloadFailed"))
    } catch {
      if !githubToken.isEmpty {
        return await fetchLatestPythonReleaseDirectViaToken()
      }
      return (nil, nil, "\(error)")
    }
  }

  /// 兜底：用户配置 GitHub Token 时直接打 GitHub API 解析资产（不被 60/h 限流）
  private func fetchLatestPythonReleaseDirectViaToken() async -> (tag: String?, url: URL?, error: String?) {
    let api = URL(string: "https://api.github.com/repos/\(Self.pythonRepoOwner)/\(Self.pythonRepoName)/releases/latest")!
    do {
      var req = URLRequest(url: api)
      req.timeoutInterval = 15
      for (k, v) in Self.githubHeaders(token: githubToken) {
        req.setValue(v, forHTTPHeaderField: k)
      }
      let (data, response) = try await URLSession.shared.data(for: req)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
        return (nil, nil, "Token 直连也失败：HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)：\(body)")
      }
      let rel = try JSONDecoder().decode(GitHubRelease.self, from: data)
      guard let asset = rel.assets.first(where: {
        $0.name.range(of: Self.pythonAssetPattern, options: .regularExpression) != nil
      }) else {
        return (nil, nil, "release \(rel.tag_name) 没有匹配 \(Self.pythonAssetPattern) 的资产")
      }
      guard let url = URL(string: asset.browser_download_url) else {
        return (nil, nil, "资产 URL 解析失败：\(asset.browser_download_url)")
      }
      return (rel.tag_name, url, nil)
    } catch {
      return (nil, nil, "Token 直连异常：\(error)")
    }
  }

  // MARK: - 运行时配置（交给 AIEnergyAgent + lua 叠加层）

  func writeRuntimeConfig(rimeDir: URL, forceEnabled: Bool? = nil) {
    let modelDir = Self.modelsDir.appending(path: modelID, directoryHint: .isDirectory).path
    let payload: [String: Any] = [
      "enabled": forceEnabled ?? engineEnabled,
      "modelID": modelID,
      "modelPath": modelDir,
      "pythonExecutable": pythonExecutable,
      "rimeDir": rimeDir.path,
      "temperature": temperature,
      "maxTokens": maxTokens,
      "topP": topP,
      "startupAtLogin": startupAtLogin,
      "updateCheckEnabled": updateCheckEnabled,
      "updateCheckIntervalDays": updateCheckIntervalDays,
      "trayIconName": trayIconName,
    ]
    // 必须用 JSONSerialization 写出真正 JSON。`NSDictionary.write(to:atomically:)` 写的是
    // property list（XML），SP-AIEnergyAgent 用 JSONSerialization 读取会失败，导致一直报
    // "aienergy_config.json 缺失"。
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted) else { return }
    let fm = FileManager.default
    try? fm.createDirectory(at: runtimeConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: runtimeConfigURL, options: [.atomic])
    // 同时写出到 Rime 用户目录，供常驻进程读取
    try? fm.createDirectory(at: rimeConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: rimeConfigURL, options: [.atomic])
    // 之前因 XML plist 解析失败留下的陈旧错误可以清掉；配置已重新正确写出。
    if let err = lastError, err.contains("aienergy_config.json") {
      lastError = nil
    }
  }

  // MARK: - 引擎子进程管理

  func startEngine() {
    stopEngine()
    guard engineEnabled else { return }
    writeRuntimeConfig(rimeDir: RimeEnvironment.userDirectory)
    guard let agentBin = Self.agentExecutableURL else {
      lastError = String(localized: "ai.error.agentBinaryMissing")
      return
    }
    lastStartAttempt = Date()
    let proc = Process()
    proc.executableURL = agentBin
    proc.terminationHandler = { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.engineRunning = false
      }
    }
    do {
      try proc.run()
      engineProcess = proc
    } catch {
      lastError = error.localizedDescription
      engineRunning = false
    }
  }

  /// 可靠地停止 AI 引擎。
  ///
  /// 多层兜底：① 终止面板可能持有的子进程；② 写出「引擎禁用」配置并广播通知，
  /// 常驻 Agent 收到后自行清理子进程；③ 按 pid 文件强杀常驻 Agent。
  func stopEngine() {
    // ① 面板子进程（若存在）
    engineProcess?.terminate()
    engineProcess = nil

    // ② 通知常驻 Agent：写出 disabled 配置并广播，Agent 会自行清理
    writeRuntimeConfig(rimeDir: RimeEnvironment.userDirectory, forceEnabled: false)
    notifyAgentConfigChanged()

    // ③ 按 pid 文件强杀常驻 Agent（最可靠路径）
    killAgentByPIDFile()

    engineRunning = false
    engineStatusMessage = String(localized: "ai.status.stopped")
    // 自行写入 stopped 状态文件，避免 Agent 崩溃/未正常退出时陈旧状态文件仍显示 running。
    writeStoppedStatusFile()
  }

  private func writeStoppedStatusFile() {
    let dict: [String: Any] = [
      "running": false,
      "message": "stopped",
      "error": "",
      "updated": ISO8601DateFormatter().string(from: Date()),
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
    try? data.write(to: statusFileURL, options: [.atomic])
  }

  /// 读取 Agent 写入的 pid 文件并发送 SIGTERM；若进程仍存活则升级为 SIGKILL。
  /// Agent 的 applicationWillTerminate 会 cascade 终止其 mlx / service 子进程，从而释放 8080。
  private func killAgentByPIDFile() {
    let pidFile = Self.appSupportDir.appendingPathComponent("sp_aienergy_agent.pid")
    guard let s = try? String(contentsOf: pidFile, encoding: .utf8),
          let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)),
          pid > 1, kill(pid, 0) == 0 else { return }
    kill(pid, SIGTERM)
    // 给 Agent 100ms 处理 SIGTERM，仍未退出则强制 SIGKILL，避免状态/端口继续占用。
    Thread.sleep(forTimeInterval: 0.1)
    if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
  }

  /// 移除开机自启动（LaunchAgent）：bootout + 删除 plist。供卸载时彻底清理。
  func removeLoginItem() {
    try? setLoginItemSync(enabled: false)
  }

  /// 清理 App Support 下的 AI 引擎残留（日志 / 状态 / pid），与 Rime 目录下的运行时目录互补，
  /// 保证「干干净净」——用户卸载后不留任何尾巴。
  func cleanupAgentArtifacts() {
    let fm = FileManager.default
    let dir = Self.appSupportDir
    let names = ["aienergy_config.json", "aienergy_status.json", "aienergy_agent.log",
                 "sp_aienergy_agent.pid", "aienergy_service_config.json"]
    for n in names { try? fm.removeItem(at: dir.appendingPathComponent(n)) }
    // 通配日志 / pid：aienergy_*.log / aienergy_*.pid
    if let entries = try? fm.contentsOfDirectory(atPath: dir.path) {
      for e in entries where e.hasPrefix("aienergy_") && (e.hasSuffix(".log") || e.hasSuffix(".pid")) {
        try? fm.removeItem(at: dir.appendingPathComponent(e))
      }
    }
    // 大模型商店遗留的临时下载目录（若有）
    try? fm.removeItem(at: dir.appendingPathComponent("AIModels"))
  }

  /// 向已运行的 SP-AIEnergyAgent 发送配置变更通知。
  func notifyAgentConfigChanged() {
    DistributedNotificationCenter.default().postNotificationName(
      .init("io.github.wolfprince12.squirrel-panel.aienergy.configChanged"),
      object: nil,
      userInfo: nil,
      deliverImmediately: true
    )
  }

  // MARK: - 看门狗（崩溃自拉）

  func startWatchdog() {
    stopWatchdog()
    watchdogTimer = Timer.scheduledTimer(timeInterval: 5.0, target: self, selector: #selector(watchdogTick), userInfo: nil, repeats: true)
  }

  func stopWatchdog() {
    watchdogTimer?.invalidate()
    watchdogTimer = nil
  }

  @objc private func watchdogTick() {
    refreshStatus()
    guard engineEnabled else { return }
    // 避免 10 秒内重复重启
    if let last = lastStartAttempt, Date().timeIntervalSince(last) < 10 { return }
    if !engineRunning {
      startEngine()
    }
  }

  // MARK: - 引擎状态轮询

  private func localizedEngineStatus(running: Bool, enabled: Bool) -> String {
    if running {
      return String(localized: "ai.status.running")
    } else if enabled {
      return String(localized: "ai.status.loading")
    } else {
      return String(localized: "ai.status.stopped")
    }
  }

  func refreshStatus() {
    guard FileManager.default.fileExists(atPath: statusFileURL.path) else {
      engineRunning = false
      engineStatusMessage = String(localized: "ai.status.stopped")
      // 没有状态文件时清掉陈旧错误，避免 SP-AIEnergyAgent 未运行时旧提示一直挂在那里。
      lastError = nil
      return
    }
    guard let data = try? Data(contentsOf: statusFileURL),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      engineRunning = false
      engineStatusMessage = String(localized: "ai.status.unknown")
      // 状态文件损坏时也清掉旧错误，避免解析失败后 stale error 一直显示。
      lastError = nil
      return
    }
    var fileRunning = (obj["running"] as? Bool) ?? false
    // Agent 异常退出时，状态文件可能残留 running=true；交叉验证真实进程 / 端口，避免显示「引擎运行中」实际已死。
    if fileRunning, !isEngineActuallyRunning() {
      fileRunning = false
      writeStoppedStatusFile()
    }
    engineRunning = fileRunning
    // 常驻进程写入的 message 是英文内部状态，不能原样显示；按运行布尔值与开关意图做本地化。
    engineStatusMessage = localizedEngineStatus(running: engineRunning, enabled: engineEnabled)
    let err = obj["error"] as? String
    lastError = err
    pythonDependencyMissing = (err?.contains("运行依赖缺失") ?? false)
      || (err?.localizedCaseInsensitiveContains("python-dependency-missing") ?? false)
  }

  /// 交叉验证：Agent PID 文件对应的进程是否仍在。
  /// 存活即认为引擎实际在运行；否则视为状态文件陈旧。
  private func isEngineActuallyRunning() -> Bool {
    let pidFile = Self.appSupportDir.appendingPathComponent("sp_aienergy_agent.pid")
    if let s = try? String(contentsOf: pidFile, encoding: .utf8),
       let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)),
       pid > 1, kill(pid, 0) == 0 {
      return true
    }
    return false
  }

  // MARK: - 开机自启动（登录项 LaunchAgent）

  /// 异步设置登录项，避免 launchctl bootstrap/bootout 在主线程同步等待，
  /// 导致面板在沙箱/权限受限环境下点击「应用」时未响应。
  private func setLoginItemAsync(enabled: Bool) {
    Task {
      try? setLoginItemSync(enabled: enabled)
    }
  }

  private func setLoginItemSync(enabled: Bool) throws {
    let agentURL = Self.agentExecutableURL
    guard let agentPath = agentURL?.path else { return }
    if enabled {
      let plist: [String: Any] = [
        "Label": loginItemLabel,
        "ProgramArguments": [agentPath],
        "RunAtLoad": true,
      ]
      let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      try data.write(to: loginItemPlistURL)
      let _ = runLaunchctl(["bootstrap", "gui/\(getuid())", loginItemPlistURL.path])
    } else {
      let _ = runLaunchctl(["bootout", "gui/\(getuid())/\(loginItemLabel)"])
      try? FileManager.default.removeItem(at: loginItemPlistURL)
    }
  }

  private func runLaunchctl(_ args: [String]) -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    try? proc.run()
    proc.waitUntilExit()
    if let data = try? pipe.fileHandleForReading.readToEnd(),
       let out = String(data: data, encoding: .utf8) {
      return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return ""
  }
}
