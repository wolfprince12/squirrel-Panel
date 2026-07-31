//
//  SchemaCatalog.swift
//  Squirrel Panel
//
//  扫描本机可用的输入方案，并读写 default.custom.yaml 中的 schema_list。
//
//  Rime 的规则：只有 *.schema.yaml 存在且已编译（生成 build/*.prism.bin 等）
//  的方案才能真正使用。这里按文件扫描，编译状态交由部署时处理。
//

import Foundation
import Yams

struct RimeSchema: Identifiable, Equatable, Hashable {
  let id: String            // schema_id，例如 luna_pinyin
  let name: String          // 朙月拼音
  let version: String?
  let author: String?
  let description: String?
  /// 方案文件所在位置，用户目录优先
  let isUserProvided: Bool

  var subtitle: String {
    var parts = [id]
    if let version, !version.isEmpty { parts.append("v\(version)") }
    return parts.joined(separator: " · ")
  }
}

enum SchemaCatalog {

  /// 扫描全部 *.schema.yaml
  static func scan(environment: RimeEnvironment) -> [RimeSchema] {
    var found: [String: RimeSchema] = [:]
    var order: [String] = []

    // 共享目录在前，用户目录覆盖之
    var directories: [(URL, Bool)] = []
    if let shared = environment.sharedSupportURL { directories.append((shared, false)) }
    directories.append((RimeEnvironment.userDirectory, true))

    for (dir, isUser) in directories {
      guard let items = try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
      for url in items where url.lastPathComponent.hasSuffix(".schema.yaml") {
        guard let schema = parse(url: url, isUserProvided: isUser) else { continue }
        if found[schema.id] == nil { order.append(schema.id) }
        found[schema.id] = schema
      }
    }
    return order.compactMap { found[$0] }.sorted { $0.name < $1.name }
  }

  private static func parse(url: URL, isUserProvided: Bool) -> RimeSchema? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    // 方案文件可能很大，只解析开头的 schema 段即可
    let head = text.split(separator: "\n", omittingEmptySubsequences: false)
      .prefix(while: { !$0.hasPrefix("switches:") && !$0.hasPrefix("engine:") })
      .joined(separator: "\n")
    guard let object = try? Yams.load(yaml: head) as? [String: Any],
          let schema = object["schema"] as? [String: Any] else {
      // 退而求其次：用文件名当 id
      let id = url.lastPathComponent.replacingOccurrences(of: ".schema.yaml", with: "")
      return RimeSchema(id: id, name: id, version: nil, author: nil,
                        description: nil, isUserProvided: isUserProvided)
    }
    let id = (schema["schema_id"] as? String)
      ?? url.lastPathComponent.replacingOccurrences(of: ".schema.yaml", with: "")
    let authors = schema["author"]
    let authorText: String? = {
      if let list = authors as? [Any] { return list.compactMap { $0 as? String }.joined(separator: "、") }
      return authors as? String
    }()
    return RimeSchema(
      id: id,
      name: (schema["name"] as? String) ?? id,
      version: schema["version"].map { "\($0)" },
      author: authorText,
      description: schema["description"] as? String,
      isUserProvided: isUserProvided
    )
  }

  // MARK: - schema_list 读写

  /// 从 default.custom.yaml 读取已启用方案；未配置时回落到 default.yaml 的默认值
  static func enabledSchemaIDs(patch: CustomYAMLFile, environment: RimeEnvironment) -> [String] {
    if let list = patch.value(forPath: "schema_list") as? [Any] {
      return extractIDs(from: list)
    }
    for url in environment.configSources(named: "default.yaml") {
      guard let text = try? String(contentsOf: url, encoding: .utf8),
            let object = try? Yams.load(yaml: text) as? [String: Any],
            let list = object["schema_list"] as? [Any] else { continue }
      return extractIDs(from: list)
    }
    return []
  }

  private static func extractIDs(from list: [Any]) -> [String] {
    list.compactMap { item in
      if let dict = item as? [String: Any] { return dict["schema"] as? String }
      return item as? String
    }
  }

  /// 写回 schema_list
  static func setEnabledSchemas(_ ids: [String], patch: CustomYAMLFile) {
    let list: [[String: String]] = ids.map { ["schema": $0] }
    patch.set(list.isEmpty ? nil : list, forPath: "schema_list")
  }
}
