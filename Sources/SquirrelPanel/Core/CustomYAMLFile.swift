//
//  CustomYAMLFile.swift
//  Squirrel Panel
//
//  Rime 的 *.custom.yaml 补丁文件读写。
//
//  设计底线：用户手写的配置一个字都不能弄丢。
//  为此做了三件事：
//    1. 解析失败时拒绝写入，绝不用空内容覆盖；
//    2. 每次写入前留一份 .bak 备份；
//    3. 只改动本面板管理的键，其余原样回写。
//

import Foundation
import Yams

/// 一个 Rime 补丁文件（squirrel.custom.yaml / default.custom.yaml ...）
final class CustomYAMLFile {

  enum LoadState: Equatable {
    /// 文件不存在，视为空补丁
    case absent
    /// 正常载入
    case loaded
    /// 文件存在但无法解析，为安全起见进入只读状态
    case unparsable(String)
  }

  let fileURL: URL
  private(set) var state: LoadState = .absent

  /// YAML 顶层内容（除 patch 外可能还有别的键，需原样保留）
  private var root: [String: Any] = [:]
  /// patch 节点内容
  private var patch: [String: Any] = [:]

  /// 是否允许写入
  var isWritable: Bool {
    if case .unparsable = state { return false }
    return true
  }

  init(fileURL: URL) {
    self.fileURL = fileURL
    load()
  }

  // MARK: - 载入

  func load() {
    root = [:]
    patch = [:]
    guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
      state = .absent
      return
    }
    do {
      let text = try String(contentsOf: fileURL, encoding: .utf8)
      if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        state = .loaded
        return
      }
      guard let object = try Yams.load(yaml: text) else {
        state = .loaded
        return
      }
      guard let mapping = object as? [String: Any] else {
        state = .unparsable(String(localized: "error.yaml.notMapping"))
        return
      }
      root = mapping
      patch = (mapping["patch"] as? [String: Any]) ?? [:]
      state = .loaded
    } catch {
      state = .unparsable(error.localizedDescription)
    }
  }

  // MARK: - 读取

  /// 按 Rime 路径读取值。同时兼容扁平写法（`style/font_point`）与嵌套写法。
  func value(forPath path: String) -> Any? {
    if let flat = patch[path] { return flat }
    let parts = path.split(separator: "/").map(String.init)
    guard parts.count > 1 else { return nil }
    // 逐段尝试：可能是「前缀扁平 + 后缀嵌套」的混合写法
    for split in stride(from: parts.count - 1, through: 1, by: -1) {
      let prefix = parts[0..<split].joined(separator: "/")
      guard var node = patch[prefix] as? [String: Any] else { continue }
      var found: Any?
      for (i, key) in parts[split...].enumerated() {
        if i == parts.count - split - 1 {
          found = node[key]
        } else if let next = node[key] as? [String: Any] {
          node = next
        } else {
          found = nil
          break
        }
      }
      if let found { return found }
    }
    return nil
  }

  func string(forPath path: String) -> String? {
    switch value(forPath: path) {
    case let v as String: return v
    case let v as Int: return String(v)
    case let v as Double: return String(v)
    case let v as Bool: return v ? "true" : "false"
    default: return nil
    }
  }

  func bool(forPath path: String) -> Bool? {
    switch value(forPath: path) {
    case let v as Bool: return v
    case let v as String: return ["true", "yes", "on", "1"].contains(v.lowercased())
    case let v as Int: return v != 0
    default: return nil
    }
  }

  func double(forPath path: String) -> Double? {
    switch value(forPath: path) {
    case let v as Double: return v
    case let v as Int: return Double(v)
    case let v as String: return Double(v)
    default: return nil
    }
  }

  func int(forPath path: String) -> Int? {
    switch value(forPath: path) {
    case let v as Int: return v
    case let v as Double: return Int(v)
    case let v as String: return Int(v)
    default: return nil
    }
  }

  /// 当前 patch 中所有键（仅顶层，含扁平路径键）
  var topLevelKeys: [String] { Array(patch.keys) }

  // MARK: - 写入

  /// 设置某个路径的值；传 nil 表示移除。
  ///
  /// 若用户原本用嵌套写法配置了同一项，则就地修改那个嵌套节点，
  /// 避免同时存在扁平键与嵌套键导致 Rime 应用顺序不确定。
  func set(_ newValue: Any?, forPath path: String) {
    if patch[path] != nil || !nestedPathExists(path) {
      if let newValue {
        patch[path] = newValue
      } else {
        patch.removeValue(forKey: path)
      }
      return
    }
    setNested(newValue, path: path)
  }

  private func nestedPathExists(_ path: String) -> Bool {
    let parts = path.split(separator: "/").map(String.init)
    guard parts.count > 1 else { return false }
    for split in stride(from: parts.count - 1, through: 1, by: -1) {
      let prefix = parts[0..<split].joined(separator: "/")
      if patch[prefix] is [String: Any] { return true }
    }
    return false
  }

  private func setNested(_ newValue: Any?, path: String) {
    let parts = path.split(separator: "/").map(String.init)
    for split in stride(from: parts.count - 1, through: 1, by: -1) {
      let prefix = parts[0..<split].joined(separator: "/")
      guard let node = patch[prefix] as? [String: Any] else { continue }
      let rest = Array(parts[split...])
      patch[prefix] = Self.updating(node, path: rest, value: newValue)
      return
    }
  }

  private static func updating(_ node: [String: Any], path: [String], value: Any?) -> [String: Any] {
    var node = node
    guard let head = path.first else { return node }
    if path.count == 1 {
      if let value {
        node[head] = value
      } else {
        node.removeValue(forKey: head)
      }
      return node
    }
    let child = (node[head] as? [String: Any]) ?? [:]
    node[head] = updating(child, path: Array(path.dropFirst()), value: value)
    return node
  }

  /// 移除一组由本面板管理的键（用于「恢复默认」），用户手写的其他键保持不动
  func removeManaged(keys: Set<String>) {
    for key in keys {
      patch.removeValue(forKey: key)
      if nestedPathExists(key) { setNested(nil, path: key) }
    }
  }

  /// 移除某个前缀下的全部键，例如 `app_options/com.apple.Terminal`
  func removeAll(withPrefix prefix: String) {
    for key in patch.keys where key == prefix || key.hasPrefix(prefix + "/") {
      patch.removeValue(forKey: key)
    }
  }

  // MARK: - 序列化

  private static let header = """
  # 由「鼠须管控制面板」(Squirrel Panel) 维护
  # https://github.com/wolfprince12/squirrel-Panel
  #
  # 本文件是 Rime 的补丁文件，用于覆盖默认配置。
  # 控制面板只会修改它认得的配置项，你手写的其他条目会原样保留。
  # 如需手动编辑，建议先在控制面板中关闭对应选项，避免两边互相覆盖。

  """

  /// 生成即将写入磁盘的完整文本
  func serialize() throws -> String {
    var output = root
    if patch.isEmpty {
      output.removeValue(forKey: "patch")
    } else {
      output["patch"] = patch
    }
    if output.isEmpty { return Self.header }
    let body = try Yams.dump(object: output, width: -1, allowUnicode: true, sortKeys: true)
    return Self.header + body
  }

  /// 写入磁盘：先备份，再原子替换
  func save() throws {
    guard isWritable else {
      throw PanelError.refusedToOverwrite(fileURL.lastPathComponent)
    }
    let text = try serialize()
    let fm = FileManager.default
    try fm.createDirectory(at: fileURL.deletingLastPathComponent(),
                           withIntermediateDirectories: true)
    if fm.fileExists(atPath: fileURL.path(percentEncoded: false)) {
      let backup = fileURL.appendingPathExtension("bak")
      try? fm.removeItem(at: backup)
      try? fm.copyItem(at: fileURL, to: backup)
    }
    try text.write(to: fileURL, atomically: true, encoding: .utf8)
  }
}

enum PanelError: LocalizedError {
  case refusedToOverwrite(String)
  case squirrelNotInstalled
  case commandFailed(String, Int32)
  /// 部署前校验发现：以下方案的 .schema.yaml 源文件缺失，已中止部署以免输入法失效
  case schemaSourcesMissing([String])

  var errorDescription: String? {
    switch self {
    case .refusedToOverwrite(let name):
      return String(format: String(localized: "error.refusedToOverwrite"), name)
    case .squirrelNotInstalled:
      return String(localized: "error.squirrelNotInstalled")
    case .commandFailed(let cmd, let code):
      return String(format: String(localized: "error.commandFailed"), cmd, code)
    case .schemaSourcesMissing(let ids):
      return String(format: String(localized: "error.schemaSourcesMissing"), ids.joined(separator: "、"))
    }
  }
}
