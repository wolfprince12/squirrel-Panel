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
  @EnvironmentObject private var store: SettingsStore
  @EnvironmentObject private var updateCenter: UpdateCenter

  @State private var packages: [DictionaryPackage] = []
  @State private var statuses: [String: PackageStatus] = [:]
  @State private var busyID: String? = nil
  @State private var logText: String = ""
  @State private var logTitle: String = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      ForEach(packages) { pkg in
        PackageCard(
          pkg: pkg,
          status: statuses[pkg.id] ?? .notInstalled,
          updateState: updateCenter.dictionaryUpdateStates[pkg.id] ?? .notApplicable,
          busy: busyID == pkg.id,
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
  }

  // MARK: - 词库包管理

  func reloadPackages() {
    packages = DictionaryPackageManager.loadRegistry()
    var st: [String: PackageStatus] = [:]
    for p in packages {
      st[p.id] = DictionaryPackageManager.status(of: p, environment: store.environment)
    }
    statuses = st
  }

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
          reloadPackages()
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
          reloadPackages()
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
        let newVersion = manifest.installedTag ?? manifest.installedCommit ?? "?"
        await MainActor.run {
          logText = String(format: String(localized: "package.log.updated"), newVersion)
          busyID = nil
          store.reload()
          reloadPackages()
          updateCenter.dictionaryUpdateStates[pkg.id] = .upToDate
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

// MARK: - PackageCard

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
          case .external:
            Button("package.button.manage", action: onInstall)
              .controlSize(.small).buttonStyle(.borderedProminent)
          case .notInstalled:
            Button("package.button.install", action: onInstall)
              .controlSize(.small).buttonStyle(.borderedProminent)
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
