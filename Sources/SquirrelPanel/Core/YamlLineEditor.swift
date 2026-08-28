//
//  YamlLineEditor.swift
//  Squirrel Panel
//
//  逐行手术式 YAML 编辑：只重写目标行，保留其它行的注释、格式与用户手改内容。
//
//  Portions adapted from TriFecta (https://github.com/thesadbee/TriFecta),
//  original author thesadbee. Licensed under GPL-3.0. 本文件随 Squirrel Panel
//  以相同协议（GPL-3.0）分发，保留原作者署名与协议声明。
//
//  本编辑器完全基于纯文本行解析，不依赖 Yams，因此不会重新序列化整个文件、
//  不会重排键顺序、不会丢掉用户写在配置文件里的注释。
//

import Foundation

public enum YamlScalar: Equatable {
  case string(String)
  case number(String)   // 裸数字/0x 十六进制字面量，如 15 / 0xAD2933F0
  case bool(Bool)

  /// 与官方基线一致：颜色等全部用裸 0x 字面量（librime 对 0x 前缀值保留 hex 表示；
  /// 输入法侧 SquirrelConfig.color(from:) 的正则也要求 0x 前缀；带引号同样兼容）。
  public static func hexColor(_ value: UInt32) -> YamlScalar {
    .number(String(format: "0x%08X", value))
  }
}

public struct YamlLineEditor {
  public private(set) var lines: [String]
  private let hadTrailingNewline: Bool

  /// 行解析结果
  struct LineInfo {
    let indent: Int
    let key: String      // 去引号后的键（如 ascii_composer/switch_key/Shift_L）
    let keyText: String  // 原样键文本（可能带引号）
  }

  public enum EditorError: Swift.Error, Equatable, CustomStringConvertible {
    case malformed(String)
    public var description: String {
      switch self {
      case .malformed(let msg): return "YamlLineEditor: \(msg)"
      }
    }
  }

  public init(text: String) {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    hadTrailingNewline = normalized.hasSuffix("\n")
    var comps = normalized.components(separatedBy: "\n")
    if comps.last == "", comps.count > 1 {
      comps.removeLast()
    }
    lines = comps
  }

  public var text: String {
    var out = lines.joined(separator: "\n")
    // YAML 文件一律以换行结尾（原始文件缺失时补上，幂等）
    if hadTrailingNewline || !lines.isEmpty {
      out += "\n"
    }
    return out
  }

  // MARK: 公开操作

  /// 设置 section 下的标量键。keyText 为文件中的键原文（可含引号）。
  public mutating func setScalar(section: String, keyText: String, value: YamlScalar) throws {
    if let sectionIndex = try findTopLevelSectionIndex(section) {
      try setScalarInSection(at: sectionIndex, keyText: keyText, value: value)
    } else {
      try appendSection(section: section, subkeys: [(keyText, value)])
    }
  }

  /// 顶层节的子键批量设置；节不存在则在文件末尾创建。
  public mutating func setSectionValues(section: String, values: [(keyText: String, value: YamlScalar)]) throws {
    if let sectionIndex = try findTopLevelSectionIndex(section) {
      for (key, value) in values {
        try setScalarInSection(at: sectionIndex, keyText: key, value: value)
      }
    } else {
      try appendSection(section: section, subkeys: values)
    }
  }

  /// 替换路径（如 ["patch", "schema_list"]）下的整个列表块。items 为不带缩进的条目文本。
  /// 块键缺失但父节存在时，在父节键行之后插入。
  public mutating func replaceBlockList(path: [String], items: [String]) throws {
    guard let keyIndex = try findPathKeyIndex(path) else {
      let parent = Array(path.dropLast())
      if let parentIndex = try findPathKeyIndex(parent) {
        let info = try parseLine(lines[parentIndex]) ?? LineInfo(
          indent: (parent.count - 1) * 2, key: parent.last ?? "", keyText: parent.last ?? ""
        )
        let keyText = path.last!
        let keyIndent = info.indent + 2
        var block = [String(repeating: " ", count: keyIndent) + keyText + ":"]
        block.append(contentsOf: items.map { String(repeating: " ", count: keyIndent + 2) + $0 })
        lines.insert(contentsOf: block, at: parentIndex + 1)
        return
      }
      throw EditorError.malformed("未找到块 \(path.joined(separator: "/"))")
    }
    let keyInfo = try parseLine(lines[keyIndex]) ?? LineInfo(
      indent: (path.count - 1) * 2, key: path.last!, keyText: path.last!
    )
    let itemIndent = keyInfo.indent + 2
    var bodyStart = keyIndex + 1
    while bodyStart < lines.count, lines[bodyStart].trimmingCharacters(in: .whitespaces).isEmpty {
      bodyStart += 1
    }
    var bodyEnd = bodyStart
    while bodyEnd < lines.count {
      let line = lines[bodyEnd]
      if line.trimmingCharacters(in: .whitespaces).isEmpty {
        bodyEnd += 1
        continue
      }
      if let info = try parseLine(line), info.indent <= keyInfo.indent {
        break
      }
      bodyEnd += 1
    }
    // 回退末尾连续空行（属于分隔）
    var lastItem = bodyEnd
    while lastItem > bodyStart, lines[lastItem - 1].trimmingCharacters(in: .whitespaces).isEmpty {
      lastItem -= 1
    }
    let indentStr = String(repeating: " ", count: itemIndent)
    let newBlock = items.map { indentStr + $0 }
    lines.replaceSubrange(bodyStart..<lastItem, with: newBlock)
  }

  // MARK: 行解析

  func parseLine(_ line: String) throws -> LineInfo? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }
    let indent = (line.prefix { $0 == " " || $0 == "\t" }).count
    if line.prefix(indent).contains("\t") {
      throw EditorError.malformed("制表符缩进：\(line)")
    }
    let rest = String(line.dropFirst(indent))
    guard let colon = Self.keyColonIndex(in: rest) else { return nil }
    let keyText = String(rest[..<colon]).trimmingCharacters(in: .whitespaces)
    guard !keyText.isEmpty else { return nil }
    return LineInfo(indent: indent, key: Self.unquote(keyText), keyText: keyText)
  }

  private static func keyColonIndex(in rest: String) -> String.Index? {
    if rest.hasPrefix("\"") || rest.hasPrefix("'") {
      let q = rest.first!
      var i = rest.index(after: rest.startIndex)
      var closing: String.Index?
      while i < rest.endIndex {
        if rest[i] == q {
          let next = rest.index(after: i)
          if next < rest.endIndex, rest[next] == q {
            i = rest.index(after: next)   // '' 转义
            continue
          }
          closing = i
          break
        }
        i = rest.index(after: i)
      }
      guard let closing = closing else { return nil }
      var j = rest.index(after: closing)
      while j < rest.endIndex, rest[j] == " " { j = rest.index(after: j) }
      if j < rest.endIndex, rest[j] == ":" { return j }
      return nil
    }
    for (offset, ch) in rest.enumerated() {
      if ch == ":" {
        let next = rest.index(rest.startIndex, offsetBy: offset + 1)
        if next == rest.endIndex || rest[next] == " " || rest[next] == "\t" || rest[next] == "#" {
          return rest.index(rest.startIndex, offsetBy: offset)
        }
      }
      if ch == " " || ch == "\t" || ch == "#" {
        return nil
      }
    }
    return nil
  }

  /// 扫描行内注释：返回（值结束位置，注释起始位置）。引号区域内的 # 不算注释。
  private static func splitCommentRaw(_ s: String) -> (String.Index, String.Index?) {
    var inSingle = false, inDouble = false
    var skipNextSingle = false, skipNextDouble = false
    var i = s.startIndex
    while i < s.endIndex {
      let c = s[i]
      if inSingle {
        if skipNextSingle { skipNextSingle = false }
        else if c == "'" {
          let next = s.index(after: i)
          if next < s.endIndex, s[next] == "'" {
            skipNextSingle = true
            i = next
          } else {
            inSingle = false
          }
        }
      } else if inDouble {
        if skipNextDouble { skipNextDouble = false }
        else if c == "\\" { skipNextDouble = true }
        else if c == "\"" { inDouble = false }
      } else {
        if c == "'" { inSingle = true }
        else if c == "\"" { inDouble = true }
        else if c == "#" {
          let prev = s.index(before: i)
          if s[prev] == " " || s[prev] == "\t" {
            return (i, i)
          }
        }
      }
      i = s.index(after: i)
    }
    return (s.endIndex, nil)
  }

  private static func unquote(_ s: String) -> String {
    guard s.count >= 2, let first = s.first, first == "'" || first == "\"" else { return s }
    let inner = String(s.dropFirst().dropLast())
    return first == "'" ? inner.replacingOccurrences(of: "''", with: "'") : inner
  }

  private static func quoteChar(of s: String) -> Character? {
    if s.count >= 2, s.first == "'", s.last == "'" { return "'" }
    if s.count >= 2, s.first == "\"", s.last == "\"" { return "\"" }
    return nil
  }

  // MARK: 节与块

  /// 顶层键的缩进 = 全部键行缩进的最小值（支持整文件统一缩进 0 或 2 的变体）
  private func topLevelIndent() throws -> Int {
    var minIndent = Int.max
    for line in lines {
      if let info = try parseLine(line) {
        minIndent = min(minIndent, info.indent)
      }
    }
    return minIndent == Int.max ? 0 : minIndent
  }

  private func findTopLevelSectionIndex(_ section: String) throws -> Int? {
    let topIndent = try topLevelIndent()
    for (i, line) in lines.enumerated() {
      if let info = try parseLine(line), info.indent == topIndent, info.key == section {
        return i
      }
    }
    return nil
  }

  private mutating func setScalarInSection(at sectionIndex: Int, keyText: String, value: YamlScalar) throws {
    let targetKey = Self.unquote(keyText)
    let sectionIndent = try parseLine(lines[sectionIndex])!.indent
    let baseIndent = sectionIndent + 2
    var i = sectionIndex + 1
    var lastBodyLine = sectionIndex
    while i < lines.count {
      let line = lines[i]
      if line.trimmingCharacters(in: .whitespaces).isEmpty {
        i += 1
        continue
      }
      guard let info = try parseLine(line) else {
        lastBodyLine = i   // 列表条目/子结构，属于节体
        i += 1
        continue
      }
      if info.indent <= sectionIndent { break }
      if info.indent == baseIndent, info.key == targetKey {
        lines[i] = replaceValue(on: line, keyText: keyText, value: value)
        return
      }
      lastBodyLine = i
      i += 1
    }
    let newLine = String(repeating: " ", count: baseIndent) + keyText + ": " + emit(value)
    lines.insert(newLine, at: lastBodyLine + 1)
  }

  /// 替换键行上的值：保留键名样式、行内引号风格、行尾注释及注释前的空白。
  func replaceValue(on line: String, keyText: String, value: YamlScalar) -> String {
    let indent = (line.prefix { $0 == " " }).count
    let rest = String(line.dropFirst(indent))
    guard let colon = Self.keyColonIndex(in: rest) else { return line }
    let keyPart = String(line.prefix(indent)) + String(rest[..<colon])
    let valueAndComment = String(rest[rest.index(after: colon)...])
    let (valueEnd, commentStart) = Self.splitCommentRaw(valueAndComment)
    let rawValuePart = String(valueAndComment[..<valueEnd])
    let quoted = Self.quoteChar(of: rawValuePart.trimmingCharacters(in: .whitespaces))
    var out = keyPart + ": " + emit(value, preferQuote: quoted)
    if let commentStart = commentStart {
      // 保留值与注释之间的原始空白
      let lastNonSpace = rawValuePart.lastIndex(where: { $0 != " " && $0 != "\t" })
      let gapStart = lastNonSpace.map { valueAndComment.index(after: $0) } ?? valueAndComment.startIndex
      let gap = gapStart < commentStart ? String(valueAndComment[gapStart..<commentStart]) : " "
      out += gap + String(valueAndComment[commentStart...])
    }
    return out
  }

  private mutating func appendSection(section: String, subkeys: [(keyText: String, value: YamlScalar)]) throws {
    let topIndent = try topLevelIndent()
    while lines.last?.isEmpty == true { _ = lines.popLast() }
    var block = [String(repeating: " ", count: topIndent) + "\(section):"]
    for (key, value) in subkeys {
      block.append(String(repeating: " ", count: topIndent + 2) + "\(key): \(emit(value))")
    }
    lines.append(contentsOf: block)
  }

  private func findPathKeyIndex(_ path: [String]) throws -> Int? {
    guard !path.isEmpty else { return nil }
    var expectedIndent = -2
    var searchFrom = 0
    for segment in path {
      var found: Int?
      var i = searchFrom
      while i < lines.count {
        guard let info = try parseLine(lines[i]) else { i += 1; continue }
        if info.indent == expectedIndent + 2, info.key == segment {
          found = i
          break
        }
        i += 1
      }
      guard let found = found else { return nil }
      expectedIndent += 2
      searchFrom = found + 1
      if segment == path.last { return found }
    }
    return nil
  }

  // MARK: 值发射

  func emit(_ scalar: YamlScalar, preferQuote: Character? = nil) -> String {
    if let q = preferQuote {
      let s = scalarString(scalar)
      if q == "'" {
        return "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
      }
      return "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    switch scalar {
    case .number(let n):
      return n
    case .bool(let b):
      return b ? "true" : "false"
    case .string(let s):
      return Self.isPlainSafe(s) ? s : "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }
  }

  private func scalarString(_ scalar: YamlScalar) -> String {
    switch scalar {
    case .number(let n): return n
    case .bool(let b): return b ? "true" : "false"
    case .string(let s): return s
    }
  }

  /// 字符串值是否可用 YAML plain style 裸写（避免被解析为其它类型或非法字符）
  static func isPlainSafe(_ s: String) -> Bool {
    if s.isEmpty { return false }
    let reserved: Set<String> = [
      "true", "false", "yes", "no", "on", "off", "null", "~",
      "True", "False", "Yes", "No", "On", "Off", "Null", "NULL",
    ]
    if reserved.contains(s) { return false }
    if Double(s) != nil { return false }
    if s.lowercased().hasPrefix("0x"), s.count > 2, s.dropFirst(2).allSatisfy({ $0.isHexDigit }) { return false }
    if let first = s.first, !(first.isLetter || first == "_") { return false }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_./,+-"))
    return s.unicodeScalars.allSatisfy { allowed.contains($0) }
  }
}

// MARK: - Squirrel Panel 扩展：适配「扁平路径键统一位于 patch: 段」的写入模型

extension YamlLineEditor {

  /// 替换路径下的整块（列表或映射）。items 为「相对块缩进」的 YAML 行（第 0 缩进），
  /// 方法内部按块实际缩进整体重缩进后替换；父键缺失时在父节键行之后插入。
  /// items 为空数组表示「整块删除（含键行）」，用于实现写 nil。
  public mutating func replaceBlockVerbatim(path: [String], items: [String]) throws {
    guard let keyIndex = try findPathKeyIndex(path) else {
      let parent = Array(path.dropLast())
      if let parentIndex = try findPathKeyIndex(parent) {
        let info = try parseLine(lines[parentIndex]) ?? LineInfo(
          indent: (parent.count - 1) * 2, key: parent.last ?? "", keyText: parent.last ?? "")
        let keyText = path.last!
        let keyIndent = info.indent + 2
        var block = [String(repeating: " ", count: keyIndent) + keyText + ":"]
        block.append(contentsOf: items.map { String(repeating: " ", count: keyIndent + 2) + $0 })
        lines.insert(contentsOf: block, at: parentIndex + 1)
        return
      }
      throw EditorError.malformed("未找到块 \(path.joined(separator: "/"))")
    }
    let keyInfo = try parseLine(lines[keyIndex]) ?? LineInfo(
      indent: (path.count - 1) * 2, key: path.last!, keyText: path.last!)
    let blockIndent = keyInfo.indent + 2
    var bodyStart = keyIndex + 1
    while bodyStart < lines.count, lines[bodyStart].trimmingCharacters(in: .whitespaces).isEmpty {
      bodyStart += 1
    }
    var bodyEnd = bodyStart
    while bodyEnd < lines.count {
      let line = lines[bodyEnd]
      if line.trimmingCharacters(in: .whitespaces).isEmpty {
        bodyEnd += 1
        continue
      }
      if let info = try parseLine(line), info.indent <= keyInfo.indent {
        break
      }
      bodyEnd += 1
    }
    var lastItem = bodyEnd
    while lastItem > bodyStart, lines[lastItem - 1].trimmingCharacters(in: .whitespaces).isEmpty {
      lastItem -= 1
    }
    if items.isEmpty {
      // 整块删除（含键行），实现写 nil；同样保留节级注释，避免误删用户内容。
      removeRangePreservingComments(keyIndex: keyIndex, keyInfo: keyInfo, bodyEnd: lastItem)
      return
    }
    let indented = items.map { String(repeating: " ", count: blockIndent) + $0 }
    lines.replaceSubrange(bodyStart..<lastItem, with: indented)
  }

  /// 删除路径下的键及其整块（含更深缩进的行），实现写 nil。键不存在则幂等无操作。
  ///
  /// 关键：删除范围 [keyIndex, bodyEnd) 内，缩进 `<=` 被删键的**注释行属于节级注释**，
  /// 与被删键无隶属关系，必须保留——否则「行级删托管键」会把它后面紧跟的用户手写注释
  /// 一起吃掉，违背「用户手写的配置一个字都不能弄丢」的设计底线。
  /// 更深缩进的注释（被删键块内的子注释）随块一起删。
  public mutating func removeKey(atPath path: [String]) throws {
    guard let keyIndex = try findPathKeyIndex(path) else { return }
    let keyInfo = try parseLine(lines[keyIndex]) ?? LineInfo(
      indent: (path.count - 1) * 2, key: path.last!, keyText: path.last!)
    let bodyEnd = try self.blockBodyEnd(from: keyIndex, keyIndent: keyInfo.indent)
    removeRangePreservingComments(keyIndex: keyIndex, keyInfo: keyInfo, bodyEnd: bodyEnd)
  }

  /// 从 keyIndex+1 起，找到第一个「缩进 <= keyIndent 的真实键值行」为止的块体右界。
  /// 注释行（parseLine 返回 nil）与更深缩进行都归入块体，不提前断开。
  private func blockBodyEnd(from keyIndex: Int, keyIndent: Int) throws -> Int {
    var bodyEnd = keyIndex + 1
    while bodyEnd < lines.count {
      let line = lines[bodyEnd]
      if line.trimmingCharacters(in: .whitespaces).isEmpty {
        bodyEnd += 1
        continue
      }
      if let info = try parseLine(line), info.indent <= keyIndent {
        break
      }
      bodyEnd += 1
    }
    return bodyEnd
  }

  /// 删除 [keyIndex, bodyEnd) 区间，但保留缩进 <= keyInfo.indent 的注释行（节级注释）。
  /// 被删键行（keyIndex）恒删；更深缩进的注释随块删。
  private mutating func removeRangePreservingComments(keyIndex: Int, keyInfo: LineInfo, bodyEnd: Int) {
    var removals = [Int]()
    for i in keyIndex..<bodyEnd {
      let line = lines[i]
      if line.trimmingCharacters(in: .whitespaces).isEmpty {
        removals.append(i)
        continue
      }
      if let _ = try? parseLine(line) {
        // 键值行（含被删键与同缩进兄弟键）：被删键在 keyIndex 必删；
        // 兄弟键不会落入本区间，因为 blockBodyEnd 已在首个 <= 缩进的兄弟键处断开。
        removals.append(i)
      } else {
        // 注释 / 无法解析行：仅当缩进 <= 被删键才保留（节级注释），否则随块删。
        let indent = (line.prefix { $0 == " " || $0 == "\t" }).count
        if indent > keyInfo.indent { removals.append(i) }
      }
    }
    for i in removals.reversed() { lines.remove(at: i) }
  }
}
