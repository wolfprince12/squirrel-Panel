//
//  DictionaryPage.swift
//  Squirrel Panel
//
//  词库与标点面板：
//  1. 用户词库图形化编辑（custom_phrase.txt 及用户级 *.dict.yaml）；
//  2. 学习词库（*.userdb，leveldb）只读展示；
//  3. 标点映射表编辑（punctuator/full_shape 与 punctuator/half_shape）。
//
//  同步配置已迁移至「备份与同步」面板（BackupSyncPage）。
//  本面板提供「用户词库图形化编辑」：借助 CustomPhraseFile 读写
//  ~/Library/Rime 下的用户词库文件。学习词库由输入法自动记录，
//  不在面板里手写编辑，误记词条在输入时用原生 Shift+Delete 删除即可。
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

/// 标点映射表的一行（key = 输入法按键，value = 逗号分隔的候选符号）
struct PunctRow: Identifiable, Hashable {
  let id = UUID()
  var key: String
  var value: String
}

struct DictionaryPage: View {
  @Environment(SettingsStore.self) private var store
  @State private var dictionaries: [UserDictInfo] = []
  @State private var editableFiles: [EditableDict] = []
  @State private var editingURL: EditableDict?
  /// 标点映射表的镜像行（编辑时只改本地镜像，防抖后写回 store 字典）
  @State private var fullRows: [PunctRow] = []
  @State private var halfRows: [PunctRow] = []
  /// 防抖提交任务：避免每输入一个字符就写回 store 触发全局重编译级联
  @State private var commitTask: Task<Void, Never>?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        // MARK: - 可编辑的用户词库文件
        editableSection

        // MARK: - 标点映射表
        punctSection

        // MARK: - 学习词库（只读）
        learningSection
      }
      .padding(20)
    }
    .onAppear(perform: load)
    .onDisappear {
      commitTask?.cancel()
      commitPunct()
    }
    .onChange(of: fullRows) { _, _ in schedulePunctCommit() }
    .onChange(of: halfRows) { _, _ in schedulePunctCommit() }
    .sheet(item: $editingURL) { dict in
      DictionaryEditor(url: dict.url)
        .environment(store)
    }
  }

  /// 防抖写回：编辑标点映射时只改本地镜像，停顿 300ms 后才写回 store，
  /// 避免每敲一个字符就触发一次全局补丁重编译。
  private func schedulePunctCommit() {
    commitTask?.cancel()
    commitTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 300_000_000)
      guard !Task.isCancelled else { return }
      commitPunct()
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

  // MARK: - 标点映射表

  private var punctSection: some View {
    SettingsGroup("punctuation.title") {
      VStack(alignment: .leading, spacing: 12) {
        Text("punctuation.hint")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        punctGroup(title: "punctuation.fullShape", rows: $fullRows)
        Divider()
        punctGroup(title: "punctuation.halfShape", rows: $halfRows)
      }
    }
  }

  private func punctGroup(title: String, rows: Binding<[PunctRow]>) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(LocalizedStringKey(title))
        .font(.subheadline.weight(.medium))
      ForEach(rows) { $row in
        HStack(spacing: 6) {
          TextField("punctuation.keyPlaceholder", text: $row.key)
            .textFieldStyle(.roundedBorder)
            .frame(width: 90)
          Text("→").foregroundStyle(.secondary)
          TextField("punctuation.valuePlaceholder", text: $row.value)
            .textFieldStyle(.roundedBorder)
          Button {
            rows.wrappedValue.removeAll { $0.id == row.id }
          } label: {
            Image(systemName: "minus.circle.fill")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.red)
          .help("generic.remove")
        }
      }
      Button {
        rows.wrappedValue.append(PunctRow(key: "", value: ""))
      } label: {
        Label("punctuation.add", systemImage: "plus")
      }
      .controlSize(.small)
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

  // MARK: - 标点：镜像行 ↔ Store 字典

  private func loadPunct() {
    fullRows = Self.dictToRows(store.fullShapePunct)
    halfRows = Self.dictToRows(store.halfShapePunct)
  }

  private func commitPunct() {
    store.fullShapePunct = Self.rowsToDict(fullRows)
    store.halfShapePunct = Self.rowsToDict(halfRows)
  }

  private static func dictToRows(_ dict: [String: Any]) -> [PunctRow] {
    dict.sorted { $0.key < $1.key }.map { key, value in
      let text: String
      if let arr = value as? [String] {
        text = arr.joined(separator: ",")
      } else {
        text = "\(value)"
      }
      return PunctRow(key: key, value: text)
    }
  }

  private static func rowsToDict(_ rows: [PunctRow]) -> [String: Any] {
    var dict: [String: Any] = [:]
    for row in rows where !row.key.isEmpty {
      let parts = row.value
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
      dict[row.key] = parts.count > 1 ? parts : (parts.first ?? "")
    }
    return dict
  }

  // MARK: - 载入

  private func load() {
    dictionaries = Self.scanDictionaries()
    editableFiles = Self.scanEditableDicts()
    loadPunct()
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
}
