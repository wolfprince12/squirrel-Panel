//
//  PackageManagerSection.swift
//  Squirrel Panel
//
//  第三方词库包管理（如雾凇拼音 rime-ice）。
//  该视图可在多个面板复用；目前放在「输入方案」面板顶部。
//

import SwiftUI

/// 单个词库包的更新状态
enum PackageUpdateState: Equatable {
  case notApplicable   // 未安装 / 外部安装，无需检查
  case checking        // 正在检查
  case upToDate        // 已是最新
  case available       // 有更新
  case unknown         // 无法判断（未记录安装版本等），但允许手动更新
  case failed(String)  // 检查失败（网络/限流等）

  var isChecking: Bool { self == .checking }
}

struct PackageManagerSection: View {
  @Environment(SettingsStore.self) private var store
  @Environment(UpdateCenter.self) private var updateCenter

  @State private var packages: [DictionaryPackage] = []
  @State private var statuses: [String: PackageStatus] = [:]
  /// 雾凇拼音（rime_ice）是否已安装；语法模型依赖它，缺失时禁用语法模型安装按钮。
  @State private var rimeIceInstalled = true
  @State private var busyID: String? = nil
  @State private var logText: String = ""
  @State private var logTitle: String = ""
  /// 完成/错误提示的自动消失定时器；in-progress 状态或新一轮操作会取消它
  @State private var dismissTask: Task<Void, Never>? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      let wanxiangInstalled = statuses["wanxiang-grammar"]?.isInstalled == true
      ForEach(packages) { pkg in
        let rimeIceMissing = pkg.isGrammar && !rimeIceInstalled
        let rimeIceBlocked = pkg.id == "rime-ice" && wanxiangInstalled
        PackageCard(
          pkg: pkg,
          status: statuses[pkg.id] ?? .notInstalled,
          updateState: updateCenter.dictionaryUpdateStates[pkg.id] ?? .notApplicable,
          busy: busyID == pkg.id,
          disabledInstallReason: rimeIceMissing ? String(localized: "package.hint.needsRimeIce") : nil,
          disabledUninstallReason: rimeIceBlocked ? String(localized: "package.hint.uninstallRimeIceNeedsGrammar") : nil,
          onInstall: { install(pkg) },
          onUninstall: { uninstall(pkg) },
          onUpdate: { update(pkg) },
          onCheck: { updateCenter.checkDictionaryOne(pkg) }
        )
      }

      if !logText.isEmpty {
        SettingsGroup(LocalizedStringKey(logTitle)) {
          ScrollView {
            Text(logText)
              .font(.system(.caption, design: .monospaced))
              .frame(maxWidth: .infinity, alignment: .leading)
              .textSelection(.enabled)
          }
          .frame(maxHeight: 160)
          .padding(8)
          .background(Color(nsColor: .textBackgroundColor))
          .clipShape(RoundedRectangle(cornerRadius: 6))
        }
      }
    }
    .onAppear(perform: reloadPackages)
    .onDisappear { dismissTask?.cancel() }
  }

  // MARK: - 词库包管理

  func reloadPackages() {
    packages = DictionaryPackageManager.loadRegistry()
    var st: [String: PackageStatus] = [:]
    for p in packages {
      st[p.id] = DictionaryPackageManager.status(of: p, environment: store.environment)
    }
    statuses = st
    rimeIceInstalled = DictionaryPackageManager.isRimeIceInstalled()
  }

  // MARK: - 日志与自动消失

  /// 操作进行中：设置标题/正文，并取消任何挂起的自动消失定时器
  private func setProgressLog(title: String, text: String) {
    dismissTask?.cancel()
    dismissTask = nil
    logTitle = title
    logText = text
  }

  /// 操作完成/失败：仅更新正文，3 秒后自动清空。
  /// 期间开始新操作会被 `setProgressLog` 取消，不会误清进行中的提示。
  private func setCompletionLog(text: String) {
    logText = text
    dismissTask?.cancel()
    dismissTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      guard !Task.isCancelled else { return }
      withAnimation(.easeOut(duration: 0.3)) {
        logText = ""
        logTitle = ""
      }
    }
  }

  /// 根据包类型返回下载中的提示文案：语法模型 vs 普通词库包。
  private func downloadingText(for pkg: DictionaryPackage) -> String {
    pkg.isGrammar
      ? String(localized: "package.log.downloading.grammar")
      : String(localized: "package.log.downloading")
  }

  private func install(_ pkg: DictionaryPackage) {
    busyID = pkg.id
    setProgressLog(
      title: String(format: String(localized: "package.log.install"), pkg.name),
      text: downloadingText(for: pkg)
    )
    Task {
      do {
        let manifest = try await DictionaryPackageManager.install(pkg: pkg, environment: store.environment)
        await MainActor.run {
          setCompletionLog(text: String(format: String(localized: "package.log.installed"), "\(manifest.addedFiles.count)"))
          busyID = nil
          store.reload()
          reloadPackages()
        }
      } catch {
        await MainActor.run {
          setCompletionLog(text: String(format: String(localized: "package.log.error"), error.localizedDescription))
          busyID = nil
        }
      }
    }
  }

  private func uninstall(_ pkg: DictionaryPackage) {
    busyID = pkg.id
    setProgressLog(
      title: String(format: String(localized: "package.log.uninstall"), pkg.name),
      text: String(localized: "package.log.removing")
    )
    Task {
      do {
        try await DictionaryPackageManager.uninstall(pkg: pkg, environment: store.environment)
        await MainActor.run {
          setCompletionLog(text: String(localized: "package.log.removed"))
          busyID = nil
          store.reload()
          reloadPackages()
        }
      } catch {
        await MainActor.run {
          setCompletionLog(text: String(format: String(localized: "package.log.error"), error.localizedDescription))
          busyID = nil
        }
      }
    }
  }

  private func update(_ pkg: DictionaryPackage) {
    busyID = pkg.id
    setProgressLog(
      title: String(format: String(localized: "package.log.update"), pkg.name),
      text: downloadingText(for: pkg)
    )
    Task {
      do {
        let manifest = try await DictionaryPackageManager.update(pkg: pkg, environment: store.environment)
        let newVersion = manifest.installedTag ?? manifest.installedCommit ?? "?"
        await MainActor.run {
          setCompletionLog(text: String(format: String(localized: "package.log.updated"), newVersion))
          busyID = nil
          store.reload()
          reloadPackages()
          updateCenter.dictionaryUpdateStates[pkg.id] = .upToDate
        }
      } catch {
        await MainActor.run {
          setCompletionLog(text: String(format: String(localized: "package.log.error"), error.localizedDescription))
          busyID = nil
        }
      }
    }
  }
}

// MARK: - PackageCard

struct PackageCard: View {
  let pkg: DictionaryPackage
  let status: PackageStatus
  let updateState: PackageUpdateState
  let busy: Bool
  /// 非 nil 时禁用「安装 / 纳入管理」按钮并展示原因（如：语法模型需先安装雾凇）。
  let disabledInstallReason: String?
  /// 非 nil 时禁用「卸载」按钮并展示原因（如：卸载雾凇前须先卸载万象语法模型）。
  let disabledUninstallReason: String?
  let onInstall: () -> Void
  let onUninstall: () -> Void
  let onUpdate: () -> Void
  let onCheck: () -> Void

  private var statusLabel: String {
    switch status {
    case .notInstalled: return String(localized: "package.status.notInstalled")
    case .installed: return String(localized: "package.status.installed")
    case .external: return String(localized: "package.status.external")
    }
  }
  private var statusColor: Color {
    switch status {
    case .notInstalled: return .secondary
    case .installed: return .green
    case .external: return .orange
    }
  }
  private var updateBadge: some View {
    Group {
      if status.isInstalled, updateState == .available {
        Text("package.status.updateAvailable")
          .font(.caption2)
          .padding(.horizontal, 6).padding(.vertical, 2)
          .background(Color.orange.opacity(0.15))
          .foregroundStyle(.orange)
          .clipShape(RoundedRectangle(cornerRadius: 4))
      }
    }
  }

  var body: some View {
    SettingsGroup("") {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(pkg.name).font(.headline)
            Text(pkg.author).font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusLabel).font(.caption).foregroundStyle(statusColor)
            updateBadge
          }
        }
        Text(pkg.description)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 10) {
          switch status {
          case .installed:
            switch updateState {
            case .available:
              Button("package.button.update", action: onUpdate)
                .controlSize(.small).buttonStyle(.borderedProminent)
            case .unknown:
              // 无法判断是否有更新时，不显示“可更新”的暗示，只提供手动更新入口
              Button("package.button.updateManual", action: onUpdate)
                .controlSize(.small)
            case .failed(let msg):
              Text(msg).font(.caption2).foregroundStyle(.red).lineLimit(1)
            case .checking:
              ProgressView().controlSize(.small)
              Text("package.status.checking").font(.caption2).foregroundStyle(.secondary)
            case .upToDate:
              Text("package.status.upToDate").font(.caption).foregroundStyle(.green)
            case .notApplicable:
              EmptyView()
            }
            Button("package.button.uninstall", action: onUninstall)
              .controlSize(.small)
              .disabled(disabledUninstallReason != nil)
            if let reason = disabledUninstallReason {
              Text(reason).font(.caption2).foregroundStyle(.secondary)
            }
          case .external:
            Button("package.button.manage", action: onInstall)
              .controlSize(.small).buttonStyle(.borderedProminent)
              .disabled(disabledInstallReason != nil)
            if let reason = disabledInstallReason {
              Text(reason).font(.caption2).foregroundStyle(.secondary)
            }
          case .notInstalled:
            Button("package.button.install", action: onInstall)
              .controlSize(.small).buttonStyle(.borderedProminent)
              .disabled(disabledInstallReason != nil)
            if let reason = disabledInstallReason {
              Text(reason).font(.caption2).foregroundStyle(.secondary)
            }
          }
          if status.isInstalled {
            if updateState.isChecking {
              Button("package.button.checking", action: {})
                .controlSize(.small)
                .disabled(true)
            } else {
              Button("package.button.checkNow", action: onCheck)
                .controlSize(.small)
            }
          }
          if let url = URL(string: pkg.homepage) {
            Link("package.button.homepage", destination: url)
              .controlSize(.small)
          }
          if busy { ProgressView().controlSize(.small) }
          Spacer()
        }
      }
    }
  }
}

extension PackageStatus {
  var isInstalled: Bool {
    if case .installed = self { return true }
    return false
  }
}
