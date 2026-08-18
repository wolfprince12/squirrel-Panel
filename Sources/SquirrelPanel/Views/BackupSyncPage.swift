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

/// 左右双栏对比 sheet（现代 macOS 面板风）
private struct CompareSheet: View {
  let dirName: String
  let fileName: String
  @State private var selectedFile: String
  @State private var lines: [SideBySideLine] = []
  @State private var identical = false
  @Environment(\.dismiss) private var dismiss

  init(dirName: String, fileName: String) {
    self.dirName = dirName
    self.fileName = fileName
    _selectedFile = State(initialValue: fileName)
  }

  private var addedCount: Int { lines.filter { $0.kind == .added }.count }
  private var removedCount: Int { lines.filter { $0.kind == .removed }.count }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      toolbar
      columnHeaders
      bodyRows
      Divider()
      footer
    }
    .frame(width: 680)
    .onAppear { loadDiff(for: selectedFile) }
  }

  // MARK: - 标题栏

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "doc.text.magnifyingglass")
        .font(.title2)
        .foregroundStyle(.tint)
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 1) {
        Text("backupSync.compare.title")
          .font(.headline)
        Text(selectedFile)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer()
      Button("common.close") { dismiss() }
        .controlSize(.small)
        .keyboardShortcut(.cancelAction)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  // MARK: - 文件选择 + 差异统计

  private var toolbar: some View {
    HStack(spacing: 12) {
      Label("backupSync.compare.file", systemImage: "doc.badge.clock")
        .font(.caption)
        .foregroundStyle(.secondary)
      Picker("", selection: $selectedFile) {
        ForEach(BackupManager.listBackupFiles(dirName: dirName), id: \.self) { f in
          Text(f).tag(f)
        }
      }
      .labelsHidden()
      .onChange(of: selectedFile) { _, newVal in loadDiff(for: newVal) }
      .pickerStyle(.menu)
      .frame(width: 240)

      Spacer()

      if identical {
        Label("backupSync.compare.identical", systemImage: "checkmark.circle.fill")
          .font(.caption.weight(.medium))
          .foregroundStyle(.green)
      } else {
        HStack(spacing: 10) {
          Label("\(addedCount)", systemImage: "plus.circle")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.green)
          Label("\(removedCount)", systemImage: "minus.circle")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.red)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  // MARK: - 左右栏列头

  private var columnHeaders: some View {
    HStack(spacing: 0) {
      columnHeader("backupSync.compare.backup", icon: "clock.arrow.circlepath")
      Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
      columnHeader("backupSync.compare.current", icon: "doc.text")
    }
  }

  private func columnHeader(_ title: LocalizedStringKey, icon: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: icon)
        .font(.caption2)
      Text(title)
        .font(.caption.weight(.semibold))
    }
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, alignment: .center)
    .padding(.vertical, 7)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  // MARK: - 双栏主体

  private var bodyRows: some View {
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { idx, line in
              sideBySideRow(line: line, side: .left, index: idx)
            }
          }
          .font(.system(.caption, design: .monospaced))
        }
        .scrollDisabled(lines.isEmpty)
        .background(Color.clear)
      }
      Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
      VStack(spacing: 0) {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { idx, line in
              sideBySideRow(line: line, side: .right, index: idx)
            }
          }
          .font(.system(.caption, design: .monospaced))
        }
        .scrollDisabled(lines.isEmpty)
        .background(Color.clear)
      }
    }
    .frame(maxHeight: min(CGFloat(lines.count) * 22 + 40, 460))
    .overlay(
      RoundedRectangle(cornerRadius: 4)
        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
    )
    .padding(2)
  }

  // MARK: - 底部说明

  private var footer: some View {
    Text("backupSync.compare.hint")
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
  }

  // MARK: - 行渲染

  @ViewBuilder
  private func sideBySideRow(line: SideBySideLine, side: Side, index: Int) -> some View {
    let text = (side == .left) ? line.leftText : line.rightText
    let no = (side == .left) ? line.leftNo : line.rightNo
    let isEmptyLine = text.isEmpty

    HStack(spacing: 0) {
      // 行号 gutter
      Text(no.map { "\($0)" } ?? "")
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.tertiary)
        .frame(width: 40, alignment: .trailing)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(lineNumberBackground(line: line, side: side))

      // 分隔线
      Rectangle()
        .fill(Color(nsColor: .separatorColor).opacity(0.5))
        .frame(width: 1)

      // 内容
      Text(text)
        .frame(maxWidth: .infinity, alignment: side == .left ? .trailing : .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .opacity(isEmptyLine ? 0 : 1)
    }
    .background(rowBackground(line: line, side: side, index: index))
    .foregroundStyle(foreground(line: line, side: side))
  }

  private enum Side { case left, right }

  /// 斑马纹 + 差异高亮（背景只落在真实行上，空白处透出窗口底色，无灰块）
  @ViewBuilder
  private func rowBackground(line: SideBySideLine, side: Side, index: Int) -> some View {
    switch line.kind {
    case .equal:
      // 偶数行透明（窗口底色），奇数行极淡条纹，制造行间节奏而不填灰
      index % 2 == 0
        ? Color.clear
        : Color(nsColor: .controlBackgroundColor).opacity(0.5)
    case .removed:
      side == .left ? Color.red.opacity(0.18) : Color.clear
    case .added:
      side == .right ? Color.green.opacity(0.18) : Color.clear
    }
  }

  @ViewBuilder
  private func lineNumberBackground(line: SideBySideLine, side: Side) -> some View {
    switch line.kind {
    case .equal:
      Color(nsColor: .controlBackgroundColor).opacity(0.35)
    case .removed:
      side == .left ? Color.red.opacity(0.35) : Color(nsColor: .controlBackgroundColor).opacity(0.35)
    case .added:
      side == .right ? Color.green.opacity(0.35) : Color(nsColor: .controlBackgroundColor).opacity(0.35)
    }
  }

  private func foreground(line: SideBySideLine, side: Side) -> Color {
    switch line.kind {
    case .equal:
      return .primary.opacity(0.75)
    case .removed:
      return side == .left ? .red : .clear
    case .added:
      return side == .right ? .green : .clear
    }
  }

  // MARK: - 数据加载

  private func loadDiff(for file: String) {
    let result = BackupManager.compareBackupSideBySide(dirName: dirName, fileName: file)
    self.lines = result.lines
    self.identical = result.identical
  }
}
