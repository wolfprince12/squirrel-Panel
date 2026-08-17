//
//  DictionaryPage.swift
//  Squirrel Panel
//
//  用户词库与同步 + 第三方词库包管理。
//  鼠须管的同步由 librime 完成，这里负责配置 installation.yaml
//  并通过官方通道触发同步。
//  第三方词库包（如雾凇拼音 rime-ice）基于内置注册表管理安装/更新/卸载。
//
//  本面板提供「用户词库图形化编辑」：借助 CustomPhraseFile 读写
//  ~/Library/Rime 下的用户词库文件（custom_phrase.txt 及用户级 *.dict.yaml）。
//  学习词库（*.userdb，leveldb）由输入法自动记录，不在面板里手写编辑，
//  误记词条在输入时用原生 Shift+Delete 删除即可。
//

import SwiftUI
import Yams

/// 学习词库（leveldb userdb）的只读信息
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

/// 可编辑用户词库的两类：自定义短语 vs 方案词库配置
enum EditableDictKind {
  case phrase   // custom_phrase.txt / custom_phrase_double.txt
  case dict     // *.dict.yaml（多为挂载系统词库的配置）

  /// 排序权重：自定义短语排在前面
  var order: Int { self == .phrase ? 0 : 1 }
}

/// 一个可被面板图形化编辑的用户词库文件（custom_phrase.txt / 用户级 *.dict.yaml）
struct EditableDict: Identifiable {
  let id = UUID()
  let url: URL
  let name: String
  let kind: EditableDictKind
  let entryCount: Int
  /// 一句话说明这个文件是做什么的，避免用户看不懂列表
  let description: String
}

struct DictionaryPage: View {
  @EnvironmentObject private var store: SettingsStore
  @State private var dictionaries: [UserDictInfo] = []
  @State private var editableFiles: [EditableDict] = []
  @State private var installationID = ""
  @State private var syncDirectory = ""
  @State private var message = ""
  @State private var editingURL: EditableDict?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        // MARK: - 可编辑的用户词库文件
        editableSection

        // MARK: - 学习词库（只读）
        learningSection

        // MARK: - 同步设置
        syncSection
      }
      .padding(20)
    }
    .onAppear(perform: load)
    .sheet(item: $editingURL) { dict in
      DictionaryEditor(url: dict.url)
        .environmentObject(store)
    }
  }

  // MARK: - 可编辑用户词库

  private var editableSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      phraseGroup
      dictGroup

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
  }

  /// 我的自定义短语（custom_phrase.txt 等）：真正放中文词的地方
  private var phraseGroup: some View {
    SettingsGroup("dictionary.files.phrase.title") {
      VStack(alignment: .leading, spacing: 10) {
        Text("dictionary.files.phrase.hint")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        let files = editableFiles.filter { $0.kind == .phrase }
        if files.isEmpty {
          Text("dictionary.files.empty")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          ForEach(files) { dict in dictRow(dict) }
        }
      }
    }
  }

  /// 方案词库配置（*.dict.yaml）：多为挂载系统词库的聚合文件
  private var dictGroup: some View {
    SettingsGroup("dictionary.files.dict.title") {
      VStack(alignment: .leading, spacing: 10) {
        Text("dictionary.files.dict.hint")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        let files = editableFiles.filter { $0.kind == .dict }
        if files.isEmpty {
          Text("dictionary.files.empty")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          ForEach(files) { dict in dictRow(dict) }
        }
      }
    }
  }

  private func dictRow(_ dict: EditableDict) -> some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(dict.name)
          Text(dict.description)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
        Button("dictionary.edit") { editingURL = dict }
          .controlSize(.small)
      }
      .padding(.vertical, 2)
      Divider()
    }
  }

  // MARK: - 学习词库（只读）

  private var learningSection: some View {
    SettingsGroup("dictionary.learning.title") {
      VStack(alignment: .leading, spacing: 10) {
        Text("dictionary.learning.hint")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

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
      }
    }
  }

  // MARK: - 同步设置

  private var syncSection: some View {
    SettingsGroup("dictionary.sync.title") {
      VStack(alignment: .leading, spacing: 12) {
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
              .frame(minWidth: 260, maxWidth: .infinity)
            Button("generic.choose") { chooseSyncDirectory() }
              .controlSize(.small)
          }
          .frame(maxWidth: .infinity)
        }
        Text("dictionary.sync.dir.hint")
          .font(.caption)
          .foregroundStyle(.secondary)

        Divider()

        HStack(alignment: .top, spacing: 10) {
          VStack(alignment: .leading, spacing: 4) {
            Button("dictionary.icloud.use") { useICloudSync() }
              .controlSize(.small)
            Text("dictionary.icloud.hint")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer()
        }

        Divider()

        HStack(spacing: 10) {
          Button("dictionary.saveAndDeploy") { saveAndDeploy() }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
          Button("dictionary.syncNowData") {
            do {
              try SquirrelBridge.sync(environment: store.environment)
              message = String(localized: "dictionary.message.syncStarted")
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
      }
    }
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
    message = String(localized: "dictionary.icloud.filled")
  }

  // MARK: - 载入与保存

  private func load() {
    dictionaries = Self.scanDictionaries()
    editableFiles = Self.scanEditableDicts()
    let url = RimeEnvironment.userDirectory.appending(path: "installation.yaml")
    guard let text = try? String(contentsOf: url, encoding: .utf8),
          let object = try? Yams.load(yaml: text) as? [String: Any] else {
      return
    }
    installationID = (object["installation_id"] as? String) ?? ""
    syncDirectory = (object["sync_dir"] as? String) ?? ""
  }

  /// 列出本机可被面板图形化编辑的用户词库文件：
  /// custom_phrase.txt / custom_phrase_double.txt，以及用户级、非软链、且体积小于
  /// 256KB 的 *.dict.yaml（MB 级系统词库如 radical_pinyin.dict.yaml 会被排除，避免误改）。
  private static func scanEditableDicts() -> [EditableDict] {
    let dir = RimeEnvironment.userDirectory
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(
      at: dir,
      includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]) else { return [] }

    let maxBytes = 256 * 1024
    return items.compactMap { url -> EditableDict? in
      let name = url.lastPathComponent
      let isPhrase = name == "custom_phrase.txt" || name == "custom_phrase_double.txt"
      let isDict = name.hasSuffix(".dict.yaml")
      guard isPhrase || isDict else { return nil }
      guard !name.hasSuffix(".schema.yaml") else { return nil }
      let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
      if values?.isSymbolicLink == true { return nil }
      let size = values?.fileSize ?? 0
      guard size < maxBytes else { return nil }
      let file = CustomPhraseFile(fileURL: url)
      let kind: EditableDictKind = isPhrase ? .phrase : .dict
      let description = Self.describe(kind: kind, count: file.entryCount, file: file)
      return EditableDict(url: url, name: name, kind: kind,
                          entryCount: file.entryCount, description: description)
    }
    .sorted {
      $0.kind.order < $1.kind.order || ($0.kind == $1.kind && $0.name < $1.name)
    }
  }

  /// 为每个可编辑文件生成一句话说明，帮助用户理解「这是什么、该点哪一个」
  private static func describe(kind: EditableDictKind, count: Int, file: CustomPhraseFile) -> String {
    switch kind {
    case .phrase:
      return String(localized: "dictionary.files.phrase.desc")
    case .dict:
      let hasCJK = file.lines.contains {
        $0.isEntry && $0.word.unicodeScalars.contains(where: { $0.properties.isIdeographic })
      }
      return hasCJK
        ? String(format: String(localized: "dictionary.files.dict.descCJK"), count)
        : String(localized: "dictionary.files.dict.descAgg")
    }
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
      message = String(localized: "dictionary.icloud.applied")
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
      message = String(localized: "dictionary.message.saved")
    } catch {
      message = error.localizedDescription
    }
  }
}
