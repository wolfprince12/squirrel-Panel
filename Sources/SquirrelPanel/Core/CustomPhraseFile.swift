//
//  CustomPhraseFile.swift
//  Squirrel Panel
//
//  雾凇拼音的自定义短语文件：全拼是 `~/Library/Rime/custom_phrase.txt`，
//  双拼是 `~/Library/Rime/custom_phrase_double.txt`（两者是各自独立的词典）。
//
//  这是 Rime 的 tabledb 文本词典，格式为「词<Tab>码<Tab>权重」，
//  文件头部的 `#@/db_name`、`#@/db_type` 指令行必须原样保留，否则词典不会被加载。
//
//  设计底线（与 CustomYAMLFile 一致）：
//    1. 注释行、空行、无法识别的行一律原样保留，绝不丢用户内容；
//    2. 写盘前先留一份 .bak；
//    3. 是否「有未保存改动」用序列化结果与载入基线比对得出，不手工标脏。
//

import Foundation

/// 短语文件中的一行。
/// `verbatim` 非 nil 表示这是注释 / 空行 / 无法解析的行，界面不展示、写盘时原样输出。
struct PhraseLine: Identifiable, Equatable {
  let id: UUID
  var verbatim: String?
  var word: String
  var code: String
  var weight: String

  init(id: UUID = UUID(),
       verbatim: String? = nil,
       word: String = "",
       code: String = "",
       weight: String = "") {
    self.id = id
    self.verbatim = verbatim
    self.word = word
    self.code = code
    self.weight = weight
  }

  /// 可编辑的短语条目（相对于注释 / 空行）
  var isEntry: Bool { verbatim == nil }

  /// 词与码都为空的条目：界面上点了「+」还没填内容，写盘时应当整行丢弃，
  /// 否则会往 tabledb 里塞一行只含制表符的垃圾数据。
  var isBlankEntry: Bool {
    verbatim == nil
      && word.trimmingCharacters(in: .whitespaces).isEmpty
      && code.trimmingCharacters(in: .whitespaces).isEmpty
  }

  /// 写回文件时的一行文本
  var serialized: String {
    if let verbatim { return verbatim }
    var fields = [word, code]
    let trimmedWeight = weight.trimmingCharacters(in: .whitespaces)
    if !trimmedWeight.isEmpty { fields.append(trimmedWeight) }
    return fields.joined(separator: "\t")
  }
}

/// 自定义短语文件的内存模型（值类型，便于直接挂在 @Published 属性上驱动界面）
struct CustomPhraseFile: Equatable {

  /// 文件不存在时新建所用的头部：Rime tabledb 必需的指令行。
  ///
  /// `#@/db_name` 必须与词典文件名一致，否则 Rime 不会加载该词典。
  /// 全拼用 `custom_phrase.txt`、双拼用 `custom_phrase_double.txt`，因此这里
  /// 不能写死，一律由 fileURL 推导。
  ///
  /// 注：rime-ice 的约定是**带 `.txt` 后缀**——其出厂 custom_phrase.txt 头部即
  /// `#@/db_name<Tab>custom_phrase.txt`，注释也明确写着「双拼需把 db_name 改为
  /// custom_phrase_double.txt」。故此处取 lastPathComponent 而非去扩展名。
  private static func defaultHeader(for fileURL: URL) -> [String] {
    let dbName = fileURL.lastPathComponent
    return [
      "# Rime table",
      "# coding: utf-8",
      "#@/db_name\t\(dbName)",
      "#@/db_type\ttabledb",
      "#",
      "# 由「鼠须管控制面板」创建。格式：词<Tab>码<Tab>权重（权重可省略）。",
      ""
    ]
  }

  let fileURL: URL
  /// 磁盘上是否已存在该文件
  private(set) var exists: Bool
  /// 全部行（含注释、空行），界面只渲染 `isEntry == true` 的行
  var lines: [PhraseLine] = []
  /// 载入（或上次保存）时的界面快照基线，用于脏值判断
  private var baseline: String = ""

  // MARK: - 载入

  init(fileURL: URL) {
    self.fileURL = fileURL
    self.exists = FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false))
    if exists, let text = try? String(contentsOf: fileURL, encoding: .utf8) {
      lines = Self.parse(text)
    } else {
      exists = false
      lines = Self.defaultHeader(for: fileURL).map { PhraseLine(verbatim: $0) }
    }
    baseline = uiSnapshot()
  }

  private static func parse(_ text: String) -> [PhraseLine] {
    text.components(separatedBy: .newlines).map { raw -> PhraseLine in
      let trimmed = raw.trimmingCharacters(in: .whitespaces)
      // 注释与空行原样保留
      if trimmed.isEmpty || trimmed.hasPrefix("#") {
        return PhraseLine(verbatim: raw)
      }
      let fields = raw.components(separatedBy: "\t")
      // 至少要有「词 + 码」两列才当作可编辑条目，否则原样保留避免破坏用户内容
      guard fields.count >= 2 else { return PhraseLine(verbatim: raw) }
      return PhraseLine(word: fields[0].trimmingCharacters(in: .whitespaces),
                        code: fields[1].trimmingCharacters(in: .whitespaces),
                        weight: fields.count >= 3 ? fields[2].trimmingCharacters(in: .whitespaces) : "")
    }
  }

  // MARK: - 查询

  /// 可编辑条目的数量
  var entryCount: Int { lines.filter(\.isEntry).count }

  /// 是否有未保存改动。
  ///
  /// 比对的是**界面快照**而不是写盘文本：刚点「+」还没填内容的空条目虽然不会被写进
  /// 文件（见 serialize()），但它确实是一次界面改动，「保存」按钮应当随之点亮，
  /// 否则用户填完第一格之前按钮是灰的，会以为面板卡住了。
  var isDirty: Bool { uiSnapshot() != baseline }

  // MARK: - 编辑

  /// 在末尾追加一条空短语
  mutating func addEntry() {
    lines.append(PhraseLine(word: "", code: "", weight: ""))
  }

  /// 删除指定 id 的短语行
  mutating func removeEntry(id: UUID) {
    lines.removeAll { $0.id == id }
  }

  /// 更新指定 id 的短语行
  mutating func update(_ line: PhraseLine) {
    guard let index = lines.firstIndex(where: { $0.id == line.id }) else { return }
    lines[index] = line
  }

  // MARK: - 序列化与写盘

  /// 序列化为**写盘**文本。
  /// 词与码都为空的条目（点了「+」但没填）整行跳过，避免往 tabledb 里写只含制表符的垃圾行。
  func serialize() -> String {
    lines.filter { !$0.isBlankEntry }.map(\.serialized).joined(separator: "\n")
  }

  /// 脏值比对用的界面快照：与 serialize() 的唯一区别是**保留**未填写的空条目，
  /// 让「新增了一行」这件事本身也算一次改动。
  private func uiSnapshot() -> String {
    lines.map(\.serialized).joined(separator: "\n")
  }

  /// 写入磁盘：先备份（.bak），再原子替换
  mutating func save() throws {
    var text = serialize()
    if !text.hasSuffix("\n") { text += "\n" }
    let fm = FileManager.default
    try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if fm.fileExists(atPath: fileURL.path(percentEncoded: false)) {
      let backup = fileURL.appendingPathExtension("bak")
      try? fm.removeItem(at: backup)
      try? fm.copyItem(at: fileURL, to: backup)
    }
    try text.write(to: fileURL, atomically: true, encoding: .utf8)
    exists = true
    baseline = uiSnapshot()
  }
}
