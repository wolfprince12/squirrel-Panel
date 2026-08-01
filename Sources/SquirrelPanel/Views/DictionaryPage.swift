//
//  DictionaryPage.swift
//  Squirrel Panel
//
//  用户词库与同步 + 第三方词库包管理。
//  鼠须管的同步由 librime 完成，这里负责配置 installation.yaml
//  并通过官方通道触发同步。
//  第三方词库包（如雾凇拼音 rime-ice）基于内置注册表管理安装/更新/卸载。
//

import SwiftUI
import Yams

struct UserDictInfo: Identifiable {
  var id: String { name }
  let name: String
  let sizeBytes: Int64
  let modified: Date?

  var sizeText: String {
    ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
  }

  var modifiedText: String {
    guard let modified else { return String(localized: "dictionary.neverUsed") }
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    return formatter.localizedString(for: modified, relativeTo: Date())
  }
}

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

struct DictionaryPage: View {
  @EnvironmentObject private var store: SettingsStore
  @EnvironmentObject private var updateCenter: UpdateCenter
  @State private var dictionaries: [UserDictInfo] = []
  @State private var installationID = ""
  @State private var syncDirectory = ""
  @State private var message = ""

  // 词库包管理
  @State private var packages: [DictionaryPackage] = []
  @State private var statuses: [String: PackageStatus] = [:]
  @State private var busyID: String? = nil
  @State private var logText: String = ""
  @State private var logTitle: String = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        // MARK: - 第三方词库包
        SettingsGroup("package.title") {
          HStack(alignment: .top, spacing: 12) {
            Text("package.intro")
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(updateCenter.dictionaryCheckingAll ? "package.checkingAll" : "package.button.checkAll") { updateCenter.checkDictionaryUpdates() }
              .controlSize(.small)
              .disabled(updateCenter.dictionaryCheckingAll)
          }
        }

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

        // MARK: - 用户词库
        SettingsGroup("dictionary.title") {
          if dictionaries.isEmpty {
            EmptyHint(text: String(localized: "dictionary.empty"))
          } else {
            ForEach(dictionaries) { dict in
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(dict.name)
                  Text("\(dict.sizeText) · " + String(format: String(localized: "dictionary.lastUpdated"), dict.modifiedText))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
              }
              .padding(.vertical, 2)
              Divider()
            }
          }
          HStack {
            Text("dictionary.location")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            Button("dictionary.openInFinder") {
              SquirrelBridge.reveal(RimeEnvironment.userDirectory)
            }
            .controlSize(.small)
          }
        }

        // MARK: - 同步设置
        SettingsGroup("dictionary.sync.title") {
          LabeledContent("dictionary.sync.id") {
            TextField("dictionary.sync.idPlaceholder", text: $installationID)
              .textFieldStyle(.roundedBorder)
              .frame(width: 220)
          }
          Text("dictionary.sync.id.hint")
            .font(.caption)
            .foregroundStyle(.secondary)

          LabeledContent("dictionary.sync.dir") {
            HStack(spacing: 6) {
              TextField("dictionary.sync.dirPlaceholder", text: $syncDirectory)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
              Button("generic.choose") { chooseSyncDirectory() }
                .controlSize(.small)
            }
          }
          Text("dictionary.sync.dir.hint")
            .font(.caption)
            .foregroundStyle(.secondary)

          Divider()
          HStack(spacing: 10) {
            Button("dictionary.save") { saveInstallation() }
            Button("dictionary.syncNowData") {
              do {
                try SquirrelBridge.sync(environment: store.environment)
                message = String(localized: "dictionary.message.syncStarted")
              } catch {
                message = error.localizedDescription
              }
            }
            .disabled(!store.environment.isInstalled)
            Spacer()
            if !message.isEmpty {
              Text(message).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }
      .padding(20)
    }
    .onAppear(perform: { load(); reloadPackages() })
  }

  // MARK: - 载入与保存

  private func load() {
    dictionaries = Self.scanDictionaries()
    let url = RimeEnvironment.userDirectory.appending(path: "installation.yaml")
    guard let text = try? String(contentsOf: url, encoding: .utf8),
          let object = try? Yams.load(yaml: text) as? [String: Any] else { return }
    installationID = (object["installation_id"] as? String) ?? ""
    syncDirectory = (object["sync_dir"] as? String) ?? ""
  }

  private static func scanDictionaries() -> [UserDictInfo] {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(
      at: RimeEnvironment.userDirectory,
      includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
      options: [.skipsHiddenFiles]) else { return [] }

    return items.filter { $0.pathExtension == "userdb" || $0.lastPathComponent.hasSuffix(".userdb") }
      .compactMap { url in
        let size = directorySize(url)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return UserDictInfo(
          name: url.lastPathComponent.replacingOccurrences(of: ".userdb", with: ""),
          sizeBytes: size,
          modified: modified)
      }
      .sorted { $0.name < $1.name }
  }

  private static func directorySize(_ url: URL) -> Int64 {
    let fm = FileManager.default
    var total: Int64 = 0
    if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
      for case let file as URL in enumerator {
        total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
      }
    }
    if total == 0 {
      total = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
    return total
  }

  private func chooseSyncDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = String(localized: "generic.choose")
    panel.message = String(localized: "dictionary.syncDir.message")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    syncDirectory = url.path(percentEncoded: false)
  }

  /// installation.yaml 由 librime 维护，这里只改动我们关心的两个字段
  private func saveInstallation() {
    let url = RimeEnvironment.userDirectory.appending(path: "installation.yaml")
    var object: [String: Any] = [:]
    if let text = try? String(contentsOf: url, encoding: .utf8),
       let existing = try? Yams.load(yaml: text) as? [String: Any] {
      object = existing
    }
    if installationID.isEmpty {
      object.removeValue(forKey: "installation_id")
    } else {
      object["installation_id"] = installationID
    }
    if syncDirectory.isEmpty {
      object.removeValue(forKey: "sync_dir")
    } else {
      object["sync_dir"] = syncDirectory
    }
    do {
      try FileManager.default.createDirectory(at: RimeEnvironment.userDirectory,
                                              withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
        let backup = url.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: url, to: backup)
      }
      let body = try Yams.dump(object: object, width: -1, allowUnicode: true, sortKeys: true)
      try body.write(to: url, atomically: true, encoding: .utf8)
      message = String(localized: "dictionary.message.saved")
    } catch {
      message = error.localizedDescription
    }
  }

  // MARK: - 词库包管理

  private func reloadPackages() {
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
        let newCommit = manifest.installedCommit ?? "?"
        await MainActor.run {
          logText = String(format: String(localized: "package.log.updated"), newCommit)
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
