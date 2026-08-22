//
//  AIEnhancedPage.swift
//  Squirrel Panel
//
//  「AI 增强」标签页：本地 MLX 小模型驱动的每键纠错 / 翻译 / 对话，
//  以及常驻引擎（LaunchAgent）的启停与状态。所有配置独立于 Rime 补丁。
//
//  2.0.0 起面板分为三部分：
//   1) 功能简介
//   2) 运行依赖（Python+MLX 运行时 / 白知新 AI 引擎 / 大模型）
//   3) 配置控制（现有配置模块）
//

import SwiftUI
import AppKit

// MARK: - 模型清单（来自 bundle 内 default_models.json）

fileprivate enum DownloadState: Equatable {
  case idle
  case downloading(String)   // 实时日志
  case done
  case failed(String)
}

fileprivate struct AIModel: Decodable, Identifiable {
  let id: String
  let name: String
  let repo: String
  let params: String
  let quant: String
  let diskMB: Int
  let minRamGB: Int
  let chinese: Bool
  let useCases: [String]
  let license: String
  let hf: String
  let modelscope: String?

  var hfURL: URL? { URL(string: hf) }
  var modelscopeURL: URL? { modelscope.flatMap { URL(string: $0) } }

  /// 是否已下载到本地模型目录。
  /// 仅有 config.json 不足以推理，必须同时存在权重文件（.safetensors / .npz），
  /// 否则「下载中断」会被误判为完成，导致引擎启动时才炸。
  var isDownloaded: Bool {
    let fm = FileManager.default
    let dir = AIConfigStore.modelsDir.appending(path: id, directoryHint: .isDirectory)
    guard fm.fileExists(atPath: dir.appending(path: "config.json").path),
          let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
    return items.contains { $0.hasSuffix(".safetensors") || $0.hasSuffix(".npz") }
  }

  enum CodingKeys: String, CodingKey {
    case id, name, repo, params, quant, chinese, license, hf, modelscope
    case useCases = "use_cases"
    case diskMB = "disk_mb"
    case minRamGB = "min_ram_gb"
  }
}

private struct ModelCatalog: Decodable {
  let models: [AIModel]
}

extension AIModel {
  static func loadAll() -> [AIModel] {
    let candidates: [URL] = [
      Bundle.main.url(forResource: "default_models", withExtension: "json"),
      // Swift Package Manager 可执行 target 打包成 .app 后，Bundle.main 可能无法定位资源，
      // 直接按 .app 的 Contents/Resources 回退读取。
      Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/default_models.json"),
      // 开发时从 .build/release 直接运行的回退。
      Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Resources/default_models.json"),
    ].compactMap { $0 }

    for url in candidates {
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      do {
        let data = try Data(contentsOf: url)
        let catalog = try JSONDecoder().decode(ModelCatalog.self, from: data)
        return catalog.models
      } catch {
        NSLog("AIModel.loadAll failed for %@: %@", url.path, error.localizedDescription)
      }
    }
    return []
  }
}

// MARK: - 局部组件

private struct AIStatusBadge: View {
  let running: Bool
  let message: String
  var body: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(running ? Color.green : Color.secondary)
        .frame(width: 9, height: 9)
      Text(message)
        .font(.callout)
        .foregroundStyle(running ? .primary : .secondary)
    }
  }
}

// MARK: - 大模型商店 Sheet（应用内直链下载）

private struct AIModelStoreSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var ai: AIConfigStore
  @State private var models: [AIModel] = []
  @State private var loadError: String? = nil

  @State private var states: [String: DownloadState] = [:]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("ai.store.title").font(.headline)
        Spacer()
        Button("button.close", role: .cancel) { dismiss() }
      }
      .padding(16)

      if models.isEmpty {
        VStack(spacing: 12) {
          Spacer()
          if let loadError {
            Text(loadError).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
          } else {
            Text("ai.store.empty").font(.callout).foregroundStyle(.secondary)
          }
          Button("ai.store.reload") { reloadModels() }
            .controlSize(.small)
          Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(models) { m in
              AIModelCard(
                m: m,
                ai: ai,
                state: Binding(
                  get: { states[m.id] ?? .idle },
                  set: { states[m.id] = $0 }
                ),
                onDownload: download,
                onRemove: removeModel
              )
            }
            Text("ai.store.note").font(.caption).foregroundStyle(.secondary)
              .padding(.horizontal, 4)
          }
          .padding(16)
        }
      }
    }
    .frame(width: 660, height: 520)
    .onAppear { reloadModels() }
  }

  private func reloadModels() {
    loadError = nil
    let loaded = AIModel.loadAll()
    if loaded.isEmpty {
      loadError = String(localized: "ai.store.loadFailed")
    } else {
      models = loaded
    }
  }

  // MARK: - 应用内下载（调用已下载的 Python 运行时的 modelscope / huggingface_hub）

  /// 下载渠道。国内网络下 ModelScope 可直连，HuggingFace 常被墙/代理拦截，
  /// 故默认按 `[.modelScope, .huggingFace]` 顺序自动回退，用户无需理解差异。
  fileprivate enum ModelChannel {
    case modelScope, huggingFace

    var label: String {
      switch self {
      case .modelScope: return "ModelScope"
      case .huggingFace: return "HuggingFace"
      }
    }

    /// 通过 argv 接收 repo/dest，避免任何字符串插值带来的转义与注入问题。
    var script: String {
      switch self {
      case .modelScope:
        return """
          import sys
          from modelscope.hub.snapshot_download import snapshot_download
          p = snapshot_download(model_id=sys.argv[1], local_dir=sys.argv[2])
          print("DONE", p, flush=True)
          """
      case .huggingFace:
        // huggingface_hub 1.x 已移除 local_dir_use_symlinks，传入会 TypeError。
        return """
          import sys
          from huggingface_hub import snapshot_download
          p = snapshot_download(repo_id=sys.argv[1], local_dir=sys.argv[2], max_workers=4)
          print("DONE", p, flush=True)
          """
      }
    }
  }

  private func download(_ m: AIModel, mirror: Bool) {
    // mirror 参数保留兼容旧调用；两个入口现在都走「自动回退」，只是起始渠道不同。
    let chain: [ModelChannel] = mirror
      ? [.modelScope, .huggingFace]
      : [.huggingFace, .modelScope]
    runDownload(m, chain: chain, at: 0)
  }

  /// 按渠道链依次尝试下载，前一个失败自动切下一个；全部失败才报错。
  private func runDownload(_ m: AIModel, chain: [ModelChannel], at index: Int) {
    guard index < chain.count else { return }
    let channel = chain[index]
    let py = ai.pythonExecutable

    // 解释器必须存在，否则给出可读提示而不是晦涩的 launch 错误
    guard FileManager.default.fileExists(atPath: py) else {
      states[m.id] = .failed("未找到 Python 运行时，请先安装「Python + MLX 运行依赖」。")
      return
    }

    let dest = AIConfigStore.modelsDir.appending(path: m.id, directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    let logURL = AIConfigStore.appSupportDir
      .appendingPathComponent("aienergy_dl_\(m.id).log")
    // FileHandle(forWritingTo:) 要求文件必须已存在，先创建空日志文件。
    if !FileManager.default.fileExists(atPath: logURL.path) {
      FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: nil)
    }

    let proc = Process()
    // 不走 pip 生成的 bin/ 控制台脚本：其 shebang 写死打包机路径，历史安装普遍
    // bad interpreter；且 huggingface-cli 在 hub 1.x 已废弃失效。统一用 `python -c`。
    proc.executableURL = URL(fileURLWithPath: py)
    proc.arguments = ["-u", "-c", channel.script, m.repo, dest.path]
    var env = ProcessInfo.processInfo.environment
    env["PYTHONUNBUFFERED"] = "1"
    env["HF_HUB_DISABLE_TELEMETRY"] = "1"
    // 清掉可能从启动环境继承的代理设置：本机代理常把模型站请求打成 502。
    for k in ["http_proxy", "https_proxy", "all_proxy",
              "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"] { env[k] = nil }
    proc.environment = env
    do {
      let fh = try FileHandle(forWritingTo: logURL)
      // 追加模式记录多次尝试，便于回溯到底哪个渠道失败
      fh.seekToEndOfFile()
      fh.write(Data("\n===== 尝试 \(index + 1)/\(chain.count)：\(channel.label) → \(m.repo) =====\n".utf8))
      proc.standardOutput = fh
      proc.standardError = fh
    } catch {
      states[m.id] = .failed("无法写入下载日志：\(error.localizedDescription)")
      return
    }

    states[m.id] = .downloading("正在从 \(channel.label) 下载 \(m.repo) …")
    proc.terminationHandler = { _ in
      let ok = proc.terminationStatus == 0 && m.isDownloaded
      // 失败时把日志尾部（真正的报错行）直接带进 UI，避免用户只看到退出码
      let tail: String = {
        guard let d = try? Data(contentsOf: logURL),
              let s = String(data: d, encoding: .utf8) else { return "" }
        return s.split(separator: "\n").map(String.init)
          .filter { !$0.isEmpty }.suffix(5).joined(separator: "\n")
      }()
      Task { @MainActor in
        if ok {
          states[m.id] = .done
          // 下载完成后把该模型设为待选用模型，等用户点「应用并重新部署」后一起生效。
          ai.pending.modelID = m.id
          return
        }
        // 本渠道失败：还有下一个就自动切换，全都失败才向用户报错
        if index + 1 < chain.count {
          states[m.id] = .downloading("\(channel.label) 失败，正在改用 \(chain[index + 1].label) …")
          runDownload(m, chain: chain, at: index + 1)
        } else if proc.terminationStatus == 0 {
          states[m.id] = .failed("下载结束但缺少 config.json，权重不完整。\n\(tail)")
        } else {
          states[m.id] = .failed("全部渠道下载失败（退出码 \(proc.terminationStatus)）\n\(tail)")
        }
      }
    }
    do { try proc.run() } catch {
      states[m.id] = .failed("无法启动下载进程：\(error.localizedDescription)")
      return
    }
    // 轮询日志，实时显示进度
    Task {
      while proc.isRunning {
        if let d = try? Data(contentsOf: logURL),
           let s = String(data: d, encoding: .utf8) {
          let tail = s.split(separator: "\n").map(String.init)
            .filter { !$0.isEmpty }.suffix(8).joined(separator: "\n")
          await MainActor.run {
            if case .downloading = states[m.id] ?? .idle { states[m.id] = .downloading(tail) }
          }
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
      }
    }
  }

  /// 卸载已下载的模型权重（仅删除该模型目录，不影响运行时与其它模型）。
  private func removeModel(_ m: AIModel) {
    // 若删除的是当前正在使用或待选中的模型，先停引擎，并把候选指向仍存在的模型。
    let wasSelected = (m.id == ai.modelID) || (m.id == ai.pending.modelID)
    if m.id == ai.modelID { ai.stopEngine() }
    if m.id == ai.pending.modelID {
      ai.pending.modelID = (ai.modelID != m.id) ? ai.modelID : AIConfigStore.defaultModelID
    }
    let dir = AIConfigStore.modelsDir.appending(path: m.id, directoryHint: .isDirectory)
    do {
      try FileManager.default.removeItem(at: dir)
      // 重建空目录，保持「已列出但未下载」的一致外观
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      states[m.id] = .idle
      models = AIModel.loadAll()   // 触发 isDownloaded 重算
      // 如果删除的是实际当前模型，也把它改成默认或仍存在的模型，避免引擎下次启动指向缺失目录。
      if wasSelected, ai.modelID == m.id {
        ai.modelID = models.first(where: { $0.isDownloaded && $0.id != m.id })?.id ?? AIConfigStore.defaultModelID
      }
    } catch {
      states[m.id] = .failed("卸载失败：\(error.localizedDescription)")
    }
  }
}

extension DownloadState {
  var isBusy: Bool {
    if case .downloading = self { return true }
    return false
  }
}

// MARK: - 单个模型卡片（抽出以控制单表达式复杂度）

private struct AIModelCard: View {
  let m: AIModel
  @Bindable var ai: AIConfigStore
  @Binding var state: DownloadState
  let onDownload: (AIModel, Bool) -> Void
  let onRemove: (AIModel) -> Void
  @State private var confirmRemove = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .top, spacing: 14) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(m.name).font(.callout).fontWeight(.semibold)
            if m.id == ai.pending.modelID {
              Text("ai.store.current").font(.caption2)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.15))
                .foregroundStyle(Color.accentColor)
                .clipShape(Capsule())
            }
            if m.isDownloaded {
              Text("ai.store.downloaded").font(.caption2).foregroundStyle(.green)
            }
          }
          let meta = [m.params, m.quant, "\(m.diskMB) MB", "需 \(m.minRamGB)GB RAM", m.license]
            .joined(separator: " · ")
          Text(meta).font(.caption).foregroundStyle(.secondary)
          let uc = m.useCases
            .map { $0 == "correct" ? String(localized: "ai.uc.correct")
                   : $0 == "translate" ? String(localized: "ai.uc.translate")
                   : String(localized: "ai.uc.chat") }
            .joined(separator: " / ")
          Text(uc).font(.caption2).foregroundStyle(.tertiary)
        }
        Spacer()
        VStack(spacing: 6) {
          Button(m.id == ai.pending.modelID ? "ai.store.using" : "ai.store.use") { ai.pending.modelID = m.id }
            .controlSize(.small).disabled(m.id == ai.pending.modelID)
          // 主按钮：自动优选渠道（国内优先 ModelScope，失败自动改用 HuggingFace）
          Button("ai.store.download") { onDownload(m, true) }
            .controlSize(.small).buttonStyle(.borderedProminent)
            .disabled(state.isBusy || ai.pythonRuntimeInstalled == false)
          if m.isDownloaded {
            Button("ai.store.remove") { confirmRemove = true }
              .controlSize(.small).disabled(state.isBusy)
          }
        }
      }
      .alert("ai.store.removeConfirm", isPresented: $confirmRemove) {
        Button("button.cancel", role: .cancel) {}
        Button("ai.store.remove", role: .destructive) { onRemove(m) }
      } message: {
        Text(String(format: String(localized: "ai.store.removeMessage"), m.name, m.diskMB))
      }

      switch state {
      case .downloading(let log):
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text("ai.store.downloading").font(.caption2).foregroundStyle(.secondary)
        }
        ScrollView {
          Text(log).font(.system(.caption2, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
        .frame(maxHeight: 90)
      case .done:
        Text("ai.store.done").font(.caption2).foregroundStyle(.green)
      case .failed(let e):
        Text(e).font(.caption2).foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
      case .idle:
        EmptyView()
      }

      HStack(spacing: 12) {
        if let u = m.hfURL { Link("ai.store.viewHF", destination: u).font(.caption2) }
        if let u = m.modelscopeURL { Link("ai.store.viewMS", destination: u).font(.caption2) }
      }
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
  }
}

// MARK: - 统一依赖卡片（与 PackageCard 同构）

/// 与 PackageManagerSection 中 PackageCard 保持一致的通用依赖卡片：
/// 标题 + 作者副标题、右上角状态徽标、描述、底部操作行。
private struct DependencyCard<Status: View, Bottom: View>: View {
  let title: LocalizedStringKey
  let author: String?
  let description: LocalizedStringKey
  @ViewBuilder let status: Status
  @ViewBuilder let bottom: Bottom

  var body: some View {
    SettingsGroup("") {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let author, !author.isEmpty {
              Text(author).font(.caption).foregroundStyle(.secondary)
            }
          }
          Spacer()
          status
        }
        Text(description)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        bottom
      }
    }
  }
}

// MARK: - Python 运行时卡片（运行依赖之一：按需从 GitHub 下载）

private struct PythonRuntimeCard: View {
  @Bindable var ai: AIConfigStore

  /// 正在进行下载/解压等写文件操作（检查更新不算，检查时应仍可点卸载/检查按钮）
  private var isFileBusy: Bool {
    switch ai.pythonRuntimeState {
    case .downloading, .extracting: return true
    default: return false
    }
  }
  private var isChecking: Bool {
    if case .checking = ai.pythonRuntimeState { return true }
    return false
  }
  private var statusColor: Color {
    ai.pythonRuntimeInstalled ? .green : .secondary
  }
  /// 将 Python 运行时状态映射为与词库包统一的 PackageUpdateState，使底部按钮布局一致
  private var pythonUpdateState: PackageUpdateState {
    switch ai.pythonRuntimeState {
    case .checking, .downloading, .extracting:
      return .checking
    case .failed(let e):
      return .failed(e)
    case .done:
      return ai.pythonUpdateAvailable ? .available : .upToDate
    case .idle:
      return ai.pythonUpdateAvailable ? .available : .notApplicable
    }
  }

  var body: some View {
    DependencyCard(
      title: "ai.python.title",
      author: String(localized: "ai.python.subtitle"),
      description: "ai.python.desc"
    ) {
      HStack(spacing: 6) {
        Circle().fill(statusColor).frame(width: 8, height: 8)
        Text(ai.pythonRuntimeInstalled ? String(localized: "ai.python.installed") : String(localized: "ai.python.notInstalled"))
          .font(.caption)
          .foregroundStyle(statusColor)
        if ai.pythonRuntimeInstalled, let tag = AIConfigStore.installedPythonTag(), !tag.isEmpty {
          Text(String(format: String(localized: "ai.python.version"), tag))
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
    } bottom: {
      HStack(spacing: 10) {
        if ai.pythonRuntimeInstalled {
          // 更新状态区：与 PackageCard 完全一致
          switch pythonUpdateState {
          case .available:
            Button("ai.python.update") { ai.installOrUpdatePython() }
              .controlSize(.small).buttonStyle(.borderedProminent)
              .disabled(isFileBusy)
          case .unknown:
            Button("package.button.updateManual") { ai.installOrUpdatePython() }
              .controlSize(.small)
              .disabled(isFileBusy)
          case .failed(let msg):
            Text(msg).font(.caption2).foregroundStyle(.red).lineLimit(2)
          case .checking:
            ProgressView().controlSize(.small)
            Text("package.status.checking").font(.caption2).foregroundStyle(.secondary)
          case .upToDate:
            Text("package.status.upToDate").font(.caption).foregroundStyle(.green)
          case .notApplicable:
            EmptyView()
          }

          // 卸载按钮：检查更新时不禁用；下载/解压写文件时禁用
          Button("ai.python.uninstall") { ai.removePythonRuntime() }
            .controlSize(.small)
            .disabled(isFileBusy)

          // 检查更新按钮：检查中时变为禁用的「检查中」
          if isChecking {
            Button("package.button.checking") {}
              .controlSize(.small)
              .disabled(true)
          } else {
            Button("package.button.checkNow") { ai.checkPythonUpdate() }
              .controlSize(.small)
          }
        } else {
          // 未安装
          if case .failed(let e) = ai.pythonRuntimeState {
            Text(e).font(.caption2).foregroundStyle(.red).lineLimit(2)
          }
          Button("ai.python.install") { ai.installOrUpdatePython() }
            .controlSize(.small).buttonStyle(.borderedProminent)
            .disabled(isFileBusy)
        }

        if isFileBusy { ProgressView().controlSize(.small) }
        Spacer()
        if let u = URL(string: "https://github.com/\(AIConfigStore.pythonRepoOwner)/\(AIConfigStore.pythonRepoName)/releases") {
          Link("package.button.homepage", destination: u).controlSize(.small)
        }
      }
    }
  }
}

// MARK: - 主页面

struct AIEnhancedPage: View {
  @Environment(AIConfigStore.self) private var ai
  @Environment(SettingsStore.self) private var store
  @Environment(UpdateCenter.self) private var updateCenter
  @State private var showingStore = false
  @State private var models: [AIModel] = []
  /// AI 引擎包（ai-energy）的安装状态与操作态
  @State private var engineStatus: PackageStatus = .notInstalled
  @State private var engineBusy = false
  @State private var engineLog: String = ""
  @State private var engineLogTitle: String = ""

  var body: some View {
    @Bindable var ai = ai
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        introSection
        engineToggleSection
        dependenciesSection
        configSection
      }
      .padding(20)
    }
    // 不再设置 .navigationTitle：避免 macOS 窗口标题栏随选中项动态变化（与"鼠须管控制面板"顶栏冲突）。
    .sheet(isPresented: $showingStore) {
      AIModelStoreSheet(ai: ai)
    }
    .onAppear {
      models = AIModel.loadAll()
      ai.refreshStatus()
      reloadEngineStatus()
      // 更新检查由 UpdateCenter + AIConfigStore 在应用启动时统一执行一次，
      // 避免每次切到本标签页都重新联网检查。
    }
  }

  // MARK: - 1) 功能简介

  private var introSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("ai.intro")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - 2) 运行依赖（三卡）

  private var dependenciesSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("ai.deps.title").font(.headline)
        Text("ai.deps.desc").font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      PythonRuntimeCard(ai: ai)
      engineCoreBlock
      modelDependencyCard

      if !engineLog.isEmpty {
        SettingsGroup(LocalizedStringKey(engineLogTitle)) {
          ScrollView {
            Text(engineLog)
              .font(.system(.caption, design: .monospaced))
              .frame(maxWidth: .infinity, alignment: .leading)
              .textSelection(.enabled)
          }
          .frame(maxHeight: 160)
        }
      }
    }
  }

  /// 白知新 AI 引擎核心（下载安装更新，沿用包管理器）
  @ViewBuilder
  private var engineCoreBlock: some View {
    DependencyCard(
      title: "ai.engineCore.title",
      author: String(localized: "ai.engineCore.credit"),
      description: "ai.engineCore.desc"
    ) {
      if case .failed(let msg) = updateCenter.aiEngineUpdateState {
        Text(msg).font(.caption2).foregroundStyle(.red).lineLimit(2)
      } else {
        HStack(spacing: 6) {
          Circle()
            .fill(engineStatus.isInstalled ? Color.green : (engineStatus.isExternal ? Color.orange : Color.secondary))
            .frame(width: 8, height: 8)
          Text(engineStatusText).font(.caption)
            .foregroundStyle(engineStatus.isInstalled ? Color.green : .secondary)
          if updateCenter.aiEngineUpdateState == .available {
            Text("package.status.updateAvailable")
              .font(.caption2)
              .padding(.horizontal, 6).padding(.vertical, 2)
              .background(Color.orange.opacity(0.15))
              .foregroundStyle(.orange)
              .clipShape(RoundedRectangle(cornerRadius: 4))
          }
        }
      }
    } bottom: {
      HStack(spacing: 10) {
        switch engineStatus {
        case .installed:
          switch updateCenter.aiEngineUpdateState {
          case .available:
            Button("package.button.update", action: updateEngine)
              .controlSize(.small).buttonStyle(.borderedProminent)
          case .unknown:
            EmptyView()
          case .checking:
            ProgressView().controlSize(.small)
            Text("package.status.checking").font(.caption2).foregroundStyle(.secondary)
          case .upToDate:
            Text("package.status.upToDate").font(.caption).foregroundStyle(.green)
          case .notApplicable, .failed:
            EmptyView()
          }
          Button("package.button.uninstall", action: uninstallEngine)
            .controlSize(.small)
        case .external:
          Button("package.button.manage", action: installEngine)
            .controlSize(.small).buttonStyle(.borderedProminent)
        case .notInstalled:
          Button("package.button.install", action: installEngine)
            .controlSize(.small).buttonStyle(.borderedProminent)
        }
        if engineStatus.isInstalled {
          if updateCenter.aiEngineUpdateState.isChecking {
            Button("package.button.checking", action: {})
              .controlSize(.small)
              .disabled(true)
          } else {
            Button("package.button.checkNow") { updateCenter.checkAIEngineUpdate() }
              .controlSize(.small)
          }
        }
        if engineBusy { ProgressView().controlSize(.small) }
        Spacer()
        if let url = URL(string: "https://github.com/BaiZhiXin/AI-Rime") {
          Link("package.button.homepage", destination: url).controlSize(.small)
        }
      }
    }
  }

  /// 大模型依赖（打开大模型商店下载 / 选用；需先安装 Python 运行时）
  @ViewBuilder
  private var modelDependencyCard: some View {
    @Bindable var ai = ai
    let count = models.filter { $0.isDownloaded }.count
    DependencyCard(
      title: "ai.models.title",
      author: nil,
      description: "ai.models.desc"
    ) {
      HStack(spacing: 6) {
        Circle()
          .fill(count > 0 ? Color.green : Color.secondary)
          .frame(width: 8, height: 8)
        Text(count > 0
             ? String(format: String(localized: "ai.models.installedCount"), count)
             : String(localized: "ai.models.none"))
          .font(.caption)
          .foregroundStyle(count > 0 ? Color.green : Color.secondary)
      }
    } bottom: {
      HStack(spacing: 10) {
        Picker("ai.model.current", selection: $ai.pending.modelID) {
          // 只列出「已下载」（config.json + 权重文件齐备）的模型；未安装的不可选。
          ForEach(models.filter { $0.isDownloaded }) { m in
            Text(m.name).tag(m.id)
          }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 260)
        Spacer()
        Button("ai.store.open") { showingStore = true }
          .controlSize(.small)
      }
    }
  }

  // MARK: - 3) 配置控制

  @ViewBuilder
  private var engineToggleSection: some View {
    @Bindable var ai = ai
    SettingsGroup("ai.config.engine") {
      // AI 增强功能开关作为独立 Switch，即时生效（不纳入「应用并重新部署」）
      HStack(spacing: 12) {
        Toggle(isOn: $ai.engineEnabled) {
          Text("ai.config.engine")
        }
        .toggleStyle(.switch)

        AIStatusBadge(
          running: ai.engineRunning && !ai.pythonDependencyMissing,
          message: ai.pythonDependencyMissing
            ? String(localized: "ai.status.dependencyMissing")
            : ai.engineStatusMessage
        )
        Spacer()
        Button("ai.status.refresh") { ai.refreshStatus() }
          .controlSize(.small)
        Button("ai.log.open") {
          NSWorkspace.shared.selectFile(AIConfigStore.appSupportDir.appendingPathComponent("aienergy_agent.log").path, inFileViewerRootedAtPath: "")
        }
        .controlSize(.small)
      }

      if ai.pythonDependencyMissing {
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          Text("ai.deps.missingHint").font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("ai.python.install") { ai.installOrUpdatePython() }
            .controlSize(.small).buttonStyle(.borderedProminent)
        }
      } else if let err = ai.lastError, !err.isEmpty {
        Label(err, systemImage: "exclamationmark.triangle.fill")
          .font(.caption).foregroundStyle(.red)
      }
    }
  }

  @ViewBuilder
  private var configSection: some View {
    @Bindable var ai = ai
    SettingsGroup("ai.config.title") {
      Divider()

      // AI 模型推理参数（联想层复用）
      LabeledContent("ai.config.temperature") {
        HStack(spacing: 8) {
          Slider(value: $ai.pending.temperature, in: 0...1, step: 0.05)
            .frame(width: 150)
          Text(String(format: "%.2f", ai.pending.temperature))
            .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            .frame(width: 44, alignment: .trailing)
        }
      }

      LabeledContent("ai.config.topP") {
        HStack(spacing: 8) {
          Slider(value: $ai.pending.topP, in: 0...1, step: 0.05)
            .frame(width: 150)
          Text(String(format: "%.2f", ai.pending.topP))
            .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            .frame(width: 44, alignment: .trailing)
        }
      }

      LabeledContent("ai.config.maxTokens") {
        Stepper(value: $ai.pending.maxTokens, in: 64...4096, step: 64) {
          Text("\(ai.pending.maxTokens)")
            .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
        }
      }

      Divider()

      // 更换系统栏驻留图标
      LabeledContent("ai.config.trayIcon") {
        Picker("", selection: $ai.pending.trayIconName) {
          ForEach(AIConfigStore.trayIconOptions, id: \.self) { name in
            HStack(spacing: 6) {
              trayIconPreview(name: name)
              Text(trayIconLabel(name: name))
            }
            .tag(name)
          }
        }
        .pickerStyle(.menu)
        .frame(width: 180)
      }
    }
  }

  private func trayIconLabel(name: String) -> String {
    switch name {
    case "MenuBarMouseTemplate": return String(localized: "ai.config.trayIcon.default")
    case "tray_mouse_head": return String(localized: "ai.config.trayIcon.mouseHead")
    case "tray_ai": return String(localized: "ai.config.trayIcon.ai")
    case "tray_mouse_chinese": return String(localized: "ai.config.trayIcon.mouseChinese")
    case "tray_wolf": return String(localized: "ai.config.trayIcon.wolf")
    default: return name
    }
  }

  private func templatedTrayIcon(from url: URL) -> NSImage? {
    guard let img = NSImage(contentsOf: url) else { return nil }
    // 关键：菜单项渲染读的是 NSImage.size，必须显式设为目标 point size，
    // 否则 SwiftUI 的 frame(width:height:) 在 NSMenuItem 里完全不生效，
    // 会按 PNG 像素尺寸（64x64 = 64pt）渲染。
    img.size = NSSize(width: 20, height: 20)
    img.isTemplate = true
    return img
  }

  @ViewBuilder
  private func trayIconPreview(name: String) -> some View {
    if let url = Bundle.main.url(forResource: "\(name)_64", withExtension: "png", subdirectory: "TrayIcons"),
       let icon = templatedTrayIcon(from: url) {
      Image(nsImage: icon)
    } else if let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "TrayIcons"),
              let icon = templatedTrayIcon(from: url) {
      Image(nsImage: icon)
    } else {
      Image(systemName: "questionmark.square")
    }
  }

  // MARK: - AI 引擎包管理（与词库包管理器同源）

  private var engineStatusText: String {
    switch engineStatus {
    case .notInstalled: return String(localized: "package.status.notInstalled")
    case .installed: return String(localized: "package.status.installed")
    case .external: return String(localized: "package.status.external")
    }
  }

  private func aiEnginePackage() -> DictionaryPackage? {
    DictionaryPackageManager.loadRegistry().first { $0.id == "ai-energy" }
  }

  private func reloadEngineStatus() {
    guard let pkg = aiEnginePackage() else { return }
    engineStatus = DictionaryPackageManager.status(of: pkg, environment: store.environment)
  }

  private func installEngine() {
    guard let pkg = aiEnginePackage() else { return }
    engineBusy = true
    engineLogTitle = String(format: String(localized: "package.log.install"), pkg.name)
    engineLog = String(localized: "package.log.downloading.aiengine")
    Task {
      do {
        let manifest = try await DictionaryPackageManager.install(pkg: pkg, environment: store.environment)
        await MainActor.run {
          engineLog = String(format: String(localized: "package.log.installed"), manifest.addedFiles.count)
          engineBusy = false
          reloadEngineStatus()
          updateCenter.checkAIEngineUpdate()
        }
      } catch {
        await MainActor.run {
          engineLog = String(format: String(localized: "package.log.error"), error.localizedDescription)
          engineBusy = false
        }
      }
    }
  }

  private func updateEngine() {
    guard let pkg = aiEnginePackage() else { return }
    engineBusy = true
    engineLogTitle = String(format: String(localized: "package.log.update"), pkg.name)
    engineLog = String(localized: "package.log.downloading.aiengine")
    Task {
      do {
        _ = try await DictionaryPackageManager.update(pkg: pkg, environment: store.environment)
        await MainActor.run {
          engineLog = String(localized: "package.log.updated")
          engineBusy = false
          reloadEngineStatus()
          updateCenter.dictionaryUpdateStates["ai-energy"] = .upToDate
        }
      } catch {
        await MainActor.run {
          engineLog = String(format: String(localized: "package.log.error"), error.localizedDescription)
          engineBusy = false
        }
      }
    }
  }

  private func uninstallEngine() {
    guard let pkg = aiEnginePackage() else { return }
    engineBusy = true
    engineLogTitle = String(format: String(localized: "package.log.uninstall"), pkg.name)
    engineLog = String(localized: "package.log.removing")
    Task {
      // 1) 先可靠停掉引擎，随后关闭「AI 增强」开关：其 didSet 会写出禁用配置、通知常驻
      //    Agent 自停，并移除开机自启动——卸载后输入法配置不残留失效的引擎引用。
      await MainActor.run {
        ai.stopEngine()
        ai.engineEnabled = false
      }
      // 2) 剥离旧版 AI-Rime 在 rime_ice.custom.yaml 的残留注入
      //    （engine/processors/@after 0 与 engine/filters 中的 lua 条目）。
      AppServices.shared.iceStore?.removeLegacyAIEnergyPatch()

      // 3) 删除所有 AI 注入文件。不依赖 manifest——AI 引擎此前可能未经包管理器记录，
      //    单纯走 manifest 卸载会因找不到清单而整段跳过，导致文件全留。这里用固定清单直接清理。
      //    注意：保留 lua/AIEnergy_processor.lua（联想层 Phase 2 将复用）。
      let rime = RimeEnvironment.userDirectory
      let knownFiles = [
        "lua/AIEnergy_filter.lua",
        "lua/AIEnergy_ipc.lua",
        "lua/AIEnergy_state.lua",
        "AIEnergy_service.py",
        "bzx_ai.py",
        "AIEnergy_config.json",
      ]
      let fm = FileManager.default
      for rel in knownFiles { try? fm.removeItem(at: rime.appending(path: rel)) }
      // 运行时根目录（Python 运行时 + 大模型 + 服务脚本）整目录删除
      try? fm.removeItem(at: AIConfigStore.runtimeHomeDir)
      // 面板管理清单与备份（兼容旧安装路径）
      try? fm.removeItem(at: rime.appending(path: ".squirrel-panel/manifests/ai-energy.json"))
      try? fm.removeItem(at: rime.appending(path: ".squirrel-panel/backups/ai-energy"))

      // 4) 部署以重载 Rime，让 build/ 重新生成并去掉 AI 注入。
      try? SquirrelBridge.deploy(environment: store.environment)

      // 5) 清理 App Support 残留；并 best-effort 走原 manifest 兼容卸载（缺失清单也不阻断）。
      await MainActor.run { ai.cleanupAgentArtifacts() }
      try? await DictionaryPackageManager.uninstall(pkg: pkg, environment: store.environment)

      await MainActor.run {
        engineLog = String(localized: "package.log.removed")
        engineBusy = false
        reloadEngineStatus()
        // 卸载后 AI 引擎开关关闭，pending 模型指向默认，避免模型指向已不存在的目录。
        ai.engineEnabled = false
        ai.pending.modelID = AIConfigStore.defaultModelID
      }
    }
  }
}
