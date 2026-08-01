//
//  PackagePage.swift
//  Squirrel Panel
//
//  第三方词库包：基于内置注册表（DictionaryPackages.json）的精选目录。
//  - 列出所有可安装的第三方词库；
//  - 每次打开面板自动检查更新；
//  - 已安装的包可手动点击「更新」升级到最新版本。
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

struct PackagePage: View {
  @EnvironmentObject private var store: SettingsStore
  @State private var packages: [DictionaryPackage] = []
  @State private var statuses: [String: PackageStatus] = [:]
  @State private var updateStates: [String: PackageUpdateState] = [:]
  @State private var busyID: String? = nil
  @State private var checkingAll = false
  @State private var logText: String = ""
  @State private var logTitle: String = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        SettingsGroup("package.title") {
          HStack(alignment: .top, spacing: 12) {
            Text("package.intro")
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(checkingAll ? "package.checkingAll" : "package.button.checkAll") { checkForUpdates() }
              .controlSize(.small)
              .disabled(checkingAll)
          }
        }

        ForEach(packages) { pkg in
          PackageCard(
            pkg: pkg,
            status: statuses[pkg.id] ?? .notInstalled,
            updateState: updateStates[pkg.id] ?? .notApplicable,
            busy: busyID == pkg.id,
            onInstall: { install(pkg) },
            onUninstall: { uninstall(pkg) },
            onUpdate: { update(pkg) },
            onCheck: { checkOne(pkg) }
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
      .padding(20)
    }
    .onAppear(perform: { reload(); checkForUpdates() })
  }

  private func reload() {
    packages = DictionaryPackageManager.loadRegistry()
    var st: [String: PackageStatus] = [:]
    for p in packages {
      st[p.id] = DictionaryPackageManager.status(of: p, environment: store.environment)
    }
    statuses = st
  }

  // MARK: - 更新检查

  private func checkForUpdates() {
    guard !checkingAll else { return }
    checkingAll = true
    // 先把已安装项标记为 checking
    var draft = updateStates
    for p in packages where (statuses[p.id] ?? .notInstalled).isInstalled {
      draft[p.id] = .checking
    }
    updateStates = draft

    let pkgs = packages
    Task {
      await withThrowingTaskGroup(of: (String, PackageUpdateState).self) { group in
        for p in pkgs where (statuses[p.id] ?? .notInstalled).isInstalled {
          group.addTask { (p.id, await computeUpdateState(for: p)) }
        }
        while let result = try? await group.next() {
          let (id, st) = result
          await MainActor.run { self.updateStates[id] = st }
        }
      }
      await MainActor.run { checkingAll = false }
    }
  }

  private func checkOne(_ pkg: DictionaryPackage) {
    Task {
      let st = await computeUpdateState(for: pkg)
      await MainActor.run { self.updateStates[pkg.id] = st }
    }
  }

  private func computeUpdateState(for pkg: DictionaryPackage) async -> PackageUpdateState {
    let status = statuses[pkg.id] ?? .notInstalled
    guard case .installed(let manifest) = status else { return .notApplicable }
    do {
      let remote = try await DictionaryPackageManager.fetchLatestCommit(pkg: pkg)
      if let installed = manifest.installedCommit {
        return installed == remote.sha ? .upToDate : .available
      }
      return .unknown
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  // MARK: - 安装 / 卸载 / 更新

  private func install(_ pkg: DictionaryPackage) {
    busyID = pkg.id
    logTitle = String(format: String(localized: "package.log.install"), pkg.name)
    logText = String(localized: "package.log.downloading")
    Task {
      do {
        let manifest = try await DictionaryPackageManager.install(pkg: pkg, environment: store.environment)
        await MainActor.run {
          logText = String(format: String(localized: "package.log.installed"), "\(manifest.addedFiles.count)")
          busyID = nil
          store.reload()
          reload()
        }
      } catch {
        await MainActor.run {
          logText = String(format: String(localized: "package.log.error"), error.localizedDescription)
          busyID = nil
        }
      }
    }
  }

  private func uninstall(_ pkg: DictionaryPackage) {
    busyID = pkg.id
    logTitle = String(format: String(localized: "package.log.uninstall"), pkg.name)
    logText = String(localized: "package.log.removing")
    Task {
      do {
        try await DictionaryPackageManager.uninstall(pkg: pkg, environment: store.environment)
        await MainActor.run {
          logText = String(localized: "package.log.removed")
          busyID = nil
          store.reload()
          reload()
        }
      } catch {
        await MainActor.run {
          logText = String(format: String(localized: "package.log.error"), error.localizedDescription)
          busyID = nil
        }
      }
    }
  }

  private func update(_ pkg: DictionaryPackage) {
    busyID = pkg.id
    logTitle = String(format: String(localized: "package.log.update"), pkg.name)
    logText = String(localized: "package.log.downloading")
    Task {
      do {
        let manifest = try await DictionaryPackageManager.update(pkg: pkg, environment: store.environment)
        let newCommit = manifest.installedCommit ?? "?"
        await MainActor.run {
          logText = String(format: String(localized: "package.log.updated"), newCommit)
          busyID = nil
          store.reload()
          reload()
          self.updateStates[pkg.id] = .upToDate
        }
      } catch {
        await MainActor.run {
          logText = String(format: String(localized: "package.log.error"), error.localizedDescription)
          busyID = nil
        }
      }
    }
  }
}

struct PackageCard: View {
  let pkg: DictionaryPackage
  let status: PackageStatus
  let updateState: PackageUpdateState
  let busy: Bool
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
            // 更新相关按钮
            switch updateState {
            case .available:
              Button("package.button.update", action: onUpdate)
                .controlSize(.small).buttonStyle(.borderedProminent)
            case .unknown:
              Button("package.button.update", action: onUpdate)
                .controlSize(.small)
            case .failed(let msg):
              Button("package.button.checkUpdate", action: onCheck)
                .controlSize(.small)
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
          case .external:
            Button("package.button.manage", action: onInstall)
              .controlSize(.small).buttonStyle(.borderedProminent)
          case .notInstalled:
            Button("package.button.install", action: onInstall)
              .controlSize(.small).buttonStyle(.borderedProminent)
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
