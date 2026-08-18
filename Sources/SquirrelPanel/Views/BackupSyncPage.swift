//
//  BackupSyncPage.swift
//  Squirrel Panel
//
//  备份与同步面板：
//  1. 同步配置（installation.yaml 的 installation_id / sync_dir），含 iCloud 一键、
//     保存并重新部署、立即同步；并展示同步状态与设备列表（P3 升级）。
//  2. 配置备份系统（P1）：整目录快照的创建 / 列表 / 整量恢复 / 删除 / 单文件行级对比。
//
//  鼠须管的同步由 librime 完成，这里负责配置 installation.yaml 并通过官方通道触发同步。
//

import SwiftUI
import Yams

/// 同步目录下的一个设备（每个子目录代表一台曾同步过的设备）
struct SyncDevice: Identifiable {
  var id: String { name }
  let name: String
  let modified: Date?
  let sizeBytes: Int64

  var sizeText: String {
    ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
  }

  var modifiedText: String {
    guard let modified else { return String(localized: "backupSync.device.never") }
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    return formatter.localizedString(for: modified, relativeTo: Date())
  }
}

/// 单文件对比的目标（用于 sheet）
struct CompareTarget: Identifiable {
  var id: String { "\(dirName)/\(fileName)" }
  let dirName: String
  let fileName: String
}

struct BackupSyncPage: View {
  @Environment(SettingsStore.self) private var store
  @State private var installationID = ""
  @State private var syncDirectory = ""
  @State private var message = ""
  @State private var backups: [BackupInfo] = []
  @State private var devices: [SyncDevice] = []
  @State private var compareTarget: CompareTarget?
  @State private var restoreTarget: String?
  @State private var deleteTarget: String?

  private var syncDirURL: URL? {
    syncDirectory.isEmpty ? nil : URL(fileURLWithPath: syncDirectory)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        syncSection
        backupSection
      }
      .padding(20)
    }
    .onAppear(perform: load)
    .sheet(item: $compareTarget) { target in
      CompareSheet(dirName: target.dirName, fileName: target.fileName)
    }
    .alert("backupSync.restore.confirmTitle", isPresented: Binding(
      get: { restoreTarget != nil },
      set: { if !$0 { restoreTarget = nil } }
    )) {
      Button("alert.cancel", role: .cancel) { restoreTarget = nil }
      Button("backupSync.restore.button", role: .destructive) {
        if let dir = restoreTarget { doRestore(dir) }
        restoreTarget = nil
      }
    } message: {
      Text("backupSync.restore.confirmMessage")
    }
    .alert("backupSync.delete.confirmTitle", isPresented: Binding(
      get: { deleteTarget != nil },
      set: { if !$0 { deleteTarget = nil } }
    )) {
      Button("alert.cancel", role: .cancel) { deleteTarget = nil }
      Button("backupSync.delete.button", role: .destructive) {
        if let dir = deleteTarget { doDelete(dir) }
        deleteTarget = nil
      }
    } message: {
      Text("backupSync.delete.confirmMessage")
    }
  }

  // MARK: - 同步配置

  private var syncSection: some View {
    SettingsGroup("backupSync.sync.title") {
      VStack(alignment: .leading, spacing: 12) {
        LabeledContent("backupSync.sync.id") {
          TextField("backupSync.sync.idPlaceholder", text: $installationID)
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
        }
        Text("backupSync.sync.id.hint")
          .font(.caption)
          .foregroundStyle(.secondary)

        LabeledContent("backupSync.sync.dir") {
          HStack(spacing: 6) {
            TextField("backupSync.sync.dirPlaceholder", text: $syncDirectory)
              .textFieldStyle(.roundedBorder)
              .frame(minWidth: 260, maxWidth: .infinity)
            Button("generic.choose") { chooseSyncDirectory() }
              .controlSize(.small)
          }
          .frame(maxWidth: .infinity)
        }
        Text("backupSync.sync.dir.hint")
          .font(.caption)
          .foregroundStyle(.secondary)

        Divider()

        HStack(alignment: .top, spacing: 10) {
          VStack(alignment: .leading, spacing: 4) {
            Button("backupSync.icloud.use") { useICloudSync() }
              .controlSize(.small)
            Text("backupSync.icloud.hint")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer()
        }

        Divider()

        HStack(spacing: 10) {
          Button("backupSync.saveAndDeploy") { saveAndDeploy() }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
          Button("backupSync.syncNow") {
            do {
              try SquirrelBridge.sync(environment: store.environment)
              message = String(localized: "backupSync.message.syncStarted")
            } catch {
              message = error.localizedDescription
            }
          }
          .controlSize(.small)
          .disabled(!store.environment.isInstalled)
          Spacer()
          if !message.isEmpty {
            Text(message)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Divider()

        // 同步状态 + 设备列表（P3 升级）
        syncStatusView
      }
    }
  }

  private var syncStatusView: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text("backupSync.status.title")
          .font(.subheadline.weight(.medium))
        Spacer()
        let configured = !syncDirectory.isEmpty
        let exists = syncDirURL.map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false
        Label(LocalizedStringKey(configured ? "backupSync.status.configured" : "backupSync.status.notConfigured"),
              systemImage: configured ? "checkmark.circle.fill" : "xmark.circle.fill")
          .font(.caption)
          .foregroundStyle(configured ? .green : .secondary)
        Label(LocalizedStringKey(exists ? "backupSync.status.dirExists" : "backupSync.status.dirMissing"),
              systemImage: exists ? "folder.fill" : "folder")
          .font(.caption)
          .foregroundStyle(exists ? .green : .secondary)
      }

      if devices.isEmpty {
        Text("backupSync.device.empty")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Text("backupSync.device.title")
          .font(.caption.weight(.medium))
        ForEach(devices) { device in
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(device.name)
              Text("\(device.sizeText) · " + String(format: String(localized: "backupSync.device.lastSeen"), device.modifiedText))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
          }
          .padding(.vertical, 2)
          Divider()
        }
      }
    }
  }

  // MARK: - 备份系统

  private var backupSection: some View {
    SettingsGroup("backupSync.backup.title") {
      VStack(alignment: .leading, spacing: 12) {
        Text("backupSync.backup.hint")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack {
          Button("backupSync.backup.create") { createBackupNow() }
            .controlSize(.small)
          Spacer()
          Text(String(format: String(localized: "backupSync.backup.count"), backups.count))
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if backups.isEmpty {
          Text("backupSync.backup.empty")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          ForEach(backups) { backup in
            VStack(spacing: 4) {
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(backup.createdText)
                  Text("\(backup.labelText) · \(backup.sizeText) · \(backup.fileCount) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
              }
              HStack(spacing: 8) {
                Button("backupSync.backup.restore") { restoreTarget = backup.dirName }
                  .controlSize(.small)
                Button("backupSync.backup.compare") {
                  let files = BackupManager.listBackupFiles(dirName: backup.dirName)
                  if let first = files.first {
                    compareTarget = CompareTarget(dirName: backup.dirName, fileName: first)
                  }
                }
                .controlSize(.small)
                Button("backupSync.backup.delete") { deleteTarget = backup.dirName }
                  .controlSize(.small)
                  .foregroundStyle(.red)
                Spacer()
              }
            }
            .padding(.vertical, 4)
            Divider()
          }
        }
      }
    }
  }

  // MARK: - 载入与保存

  private func load() {
    let url = RimeEnvironment.userDirectory.appending(path: "installation.yaml")
    if let text = try? String(contentsOf: url, encoding: .utf8),
       let object = try? Yams.load(yaml: text) as? [String: Any] {
      installationID = (object["installation_id"] as? String) ?? ""
      syncDirectory = (object["sync_dir"] as? String) ?? ""
    }
    backups = BackupManager.listBackups()
    devices = scanDevices()
  }

  /// 将同步目录指向 iCloud 云盘并填入安装标识；不会自动保存，需点击「保存并重新部署」。
  private func useICloudSync() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let iCloud = home
      .appendingPathComponent("Library")
      .appendingPathComponent("Mobile Documents")
      .appendingPathComponent("com~apple~CloudDocs")
      .appendingPathComponent("RimeSync")
    do {
      try FileManager.default.createDirectory(at: iCloud, withIntermediateDirectories: true)
      SquirrelBridge.setFolderIcon(at: iCloud)
    } catch {
      message = error.localizedDescription
      return
    }
    syncDirectory = iCloud.path(percentEncoded: false)
    if installationID.isEmpty {
      let suffix = String(format: "%08X", arc4random())
      installationID = "device-\(suffix)"
    }
    message = String(localized: "backupSync.icloud.filled")
  }

  private func chooseSyncDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = String(localized: "generic.choose")
    panel.message = String(localized: "backupSync.syncDir.message")
    if !syncDirectory.isEmpty, FileManager.default.fileExists(atPath: syncDirectory) {
      panel.directoryURL = URL(fileURLWithPath: syncDirectory)
    }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    syncDirectory = url.path(percentEncoded: false)
  }

  /// 保存 installation.yaml 并触发重新部署，使同步目录立即生效。
  private func saveAndDeploy() {
    saveInstallation()
    do {
      try SquirrelBridge.deploy(environment: store.environment)
      message = String(localized: "backupSync.icloud.applied")
    } catch {
      message = error.localizedDescription
    }
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
      message = String(localized: "backupSync.message.saved")
      devices = scanDevices()
    } catch {
      message = error.localizedDescription
    }
  }

  private func scanDevices() -> [SyncDevice] {
    guard let dir = syncDirURL,
          FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)) else { return [] }
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(
      at: dir,
      includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
      options: [.skipsHiddenFiles]) else { return [] }
    return items.filter { $0.hasDirectoryPath }.compactMap { url in
      let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
      let size = Self.directorySize(url)
      return SyncDevice(name: url.lastPathComponent, modified: modified, sizeBytes: size)
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
    return total
  }

  // MARK: - 备份操作

  private func createBackupNow() {
    do {
      let info = try BackupManager.createBackup(label: nil)
      message = String(format: String(localized: "backupSync.backup.created"), info.createdText)
      backups = BackupManager.listBackups()
    } catch {
      message = error.localizedDescription
    }
  }

  private func doRestore(_ dirName: String) {
    do {
      try BackupManager.restoreBackup(dirName: dirName)
      // 恢复后重新加载配置使生效
      try? SquirrelBridge.deploy(environment: store.environment)
      message = String(localized: "backupSync.backup.restored")
      backups = BackupManager.listBackups()
    } catch {
      message = error.localizedDescription
    }
  }

  private func doDelete(_ dirName: String) {
    do {
      try BackupManager.deleteBackup(dirName: dirName)
      backups = BackupManager.listBackups()
    } catch {
      message = error.localizedDescription
    }
  }
}

/// 单文件行级对比 sheet
private struct CompareSheet: View {
  let dirName: String
  let fileName: String
  @State private var selectedFile: String
  @Environment(\.dismiss) private var dismiss

  init(dirName: String, fileName: String) {
    self.dirName = dirName
    self.fileName = fileName
    _selectedFile = State(initialValue: fileName)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("backupSync.compare.title")
          .font(.headline)
        Spacer()
        Button("generic.close") { dismiss() }
          .controlSize(.small)
      }
      Picker("backupSync.compare.file", selection: $selectedFile) {
        ForEach(BackupManager.listBackupFiles(dirName: dirName), id: \.self) { f in
          Text(f).tag(f)
        }
      }
      .pickerStyle(.menu)
      Divider()
      let lines = BackupManager.compareBackup(dirName: dirName, fileName: selectedFile)
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(lines) { line in
            HStack(spacing: 0) {
              Text(prefix(for: line.kind))
                .frame(width: 18, alignment: .center)
                .foregroundStyle(.secondary)
              Text(line.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color(for: line.kind))
              Spacer()
            }
            .background(line.kind == .equal ? Color.clear : color(for: line.kind).opacity(0.12))
          }
        }
      }
      .frame(maxHeight: 400)
    }
    .padding(16)
    .frame(width: 560)
  }

  private func prefix(for kind: DiffKind) -> String {
    switch kind { case .added: return "+"; case .removed: return "-"; case .equal: return " " }
  }

  private func color(for kind: DiffKind) -> Color {
    switch kind { case .added: return .green; case .removed: return .red; case .equal: return .primary }
  }
}
