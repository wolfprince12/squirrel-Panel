//
//  UserColorSchemes.swift
//  Squirrel Panel
//
//  用户自定义配色方案：模型、持久化与管理器。
//
//  与开发者（大狼）专属方案（DeveloperColorSchemes，内置 JSON、只读）不同，
//  这里的是用户自己创作、可编辑、可删除的方案。它们是「命名方案」，
//  写入 squirrel.custom.yaml 的 preset_color_schemes/<id>，随方案名生效、
//  可进入大预览窗、可导出为独立 .yaml、可再导入。
//
//  持久化：注册表存于 ~/Library/Rime/user_color_schemes.json（用户 Rime 配置目录），
//  是编辑器的工作集与权威来源；apply() 再把其中全部方案注入 squirrel.custom.yaml，
//  让鼠须管实际渲染。颜色值始终以字符串 "0xBBGGRR" 保存，避免任何整数化改写。
//

import Foundation
import SwiftUI
import Yams

/// 一套用户自定义配色方案（可 Codable 持久化）
struct UserColorScheme: Identifiable, Codable {
  var id: String
  var name: String
  var author: String
  /// 颜色空间："srgb"（默认）或 "display_p3"
  var colorSpace: String
  /// 颜色字段，键为 back_color 之类的短名，值为 Rime 的 BGR 倒序十六进制字面量（"0xBBGGRR"）
  var colors: [String: String]

  /// 生成一个全局唯一、合法的文件/方案 id（小写、连字符）
  static func makeID(from name: String) -> String {
    let base = name.lowercased()
      .trimmingCharacters(in: .whitespaces)
      .replacingOccurrences(of: "[^a-z0-9一-龥]+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let cleaned = base.isEmpty ? "scheme" : base
    // 确保不与既有 id 冲突由调用方负责，这里只做基础清洗
    return "user_" + cleaned
  }
}

/// 注册表磁盘格式（方案列表 + 已注入过的 id 集合 + 用户确认使用的方案 id）
private struct RegistryFile: Codable {
  var schemes: [UserColorScheme]
  var managedIDs: [String]
  /// 用户「确认使用」的那一套自定义方案 id。与全局 colorSchemeID 解耦：
  /// 外观页自定义模块只展示它，点别的方案也不会让它消失。
  var confirmedID: String?
}

enum UserColorSchemes {

  // MARK: - 内存缓存

  /// 注册表内存缓存：避免外观面板每次打开都同步读盘 user_color_schemes.json。
  /// 所有写盘路径都经 `persist(_:)`，写完立即刷新缓存；读路径优先走缓存。
  private static var registryCache: RegistryFile?

  // MARK: - 读取

  static var all: [UserColorScheme] { load() }
  static var ids: Set<String> { Set(all.map { $0.id }) }
  static var managedIDs: Set<String> {
    get { Set(loadRegistry()?.managedIDs ?? []) }
    set { persist(managedIDs: Array(newValue)) }
  }

  /// 用户「确认使用」的那一套自定义方案 id（与全局 colorSchemeID 完全独立）
  static var confirmedID: String? {
    get { loadRegistry()?.confirmedID }
    set {
      let current = loadRegistry() ?? RegistryFile(schemes: [], managedIDs: [], confirmedID: nil)
      persist(RegistryFile(schemes: current.schemes, managedIDs: current.managedIDs, confirmedID: newValue))
    }
  }

  /// 标记某方案为「确认使用的自定义方案」
  static func confirm(_ id: String) { confirmedID = id }

  /// 当前确认使用的自定义方案（若有）
  static func confirmedScheme() -> UserColorScheme? {
    guard let id = confirmedID else { return nil }
    return all.first { $0.id == id }
  }

  private static func registryURL() -> URL? {
    // 注册表随用户自定义数据一律落在 Rime 配置目录（~/Library/Rime），
    // 不污染 App 的 Application Support 目录。
    return RimeEnvironment.userDirectory
      .appendingPathComponent("user_color_schemes.json")
  }

  private static func loadRegistry() -> RegistryFile? {
    if let cached = registryCache { return cached }
    guard let url = registryURL(),
          let data = try? Data(contentsOf: url),
          let reg = try? JSONDecoder().decode(RegistryFile.self, from: data) else {
      registryCache = nil
      return nil
    }
    registryCache = reg
    return reg
  }

  static func load() -> [UserColorScheme] {
    loadRegistry()?.schemes ?? []
  }

  // MARK: - 写入

  /// 新增或更新一套方案（按 id 去重覆盖），并持久化
  static func save(_ scheme: UserColorScheme) {
    var list = load()
    if let idx = list.firstIndex(where: { $0.id == scheme.id }) {
      list[idx] = scheme
    } else {
      list.append(scheme)
    }
    persist(schemes: list)
  }

  /// 删除一套方案。
  /// managedIDs 不在这里摘除，而是交给 apply() 通过「当前注册表 ids vs 已注入 ids」
  /// 的差集来清理 squirrel.custom.yaml，否则已删除方案会残留在补丁中。
  static func remove(id: String) {
    let list = load().filter { $0.id != id }
    let current = loadRegistry()
    var confirmed = current?.confirmedID
    if confirmed == id { confirmed = nil }
    persist(RegistryFile(schemes: list,
                         managedIDs: current?.managedIDs ?? [],
                         confirmedID: confirmed))
  }

  private static func persist(_ reg: RegistryFile) {
    // 写完立即刷新内存缓存，保证后续读取不再回源磁盘
    registryCache = reg
    guard let url = registryURL(), let data = try? JSONEncoder().encode(reg) else { return }
    try? data.write(to: url, options: .atomic)
  }

  private static func persist(schemes: [UserColorScheme], managedIDs: [String]? = nil) {
    let current = loadRegistry()
    persist(RegistryFile(
      schemes: schemes,
      managedIDs: managedIDs ?? current?.managedIDs ?? [],
      confirmedID: current?.confirmedID
    ))
  }

  private static func persist(managedIDs: [String]) {
    let current = loadRegistry()
    persist(RegistryFile(schemes: current?.schemes ?? [], managedIDs: managedIDs,
                         confirmedID: current?.confirmedID))
  }

  // MARK: - 转换为界面/注入所需结构

  /// 构造 RimeColorSchemeInfo 供色卡预览渲染
  static func info(for scheme: UserColorScheme) -> RimeColorSchemeInfo {
    var raw: [String: RimeColor] = [:]
    for (key, value) in scheme.colors where !value.isEmpty {
      if let c = RimeColor(yamlValue: value) { raw[key] = c }
    }
    return RimeColorSchemeInfo(
      id: scheme.id,
      name: scheme.name.isEmpty ? scheme.id : scheme.name,
      author: scheme.author.isEmpty ? nil : scheme.author,
      colorSpace: RimeColorSpace.from(name: scheme.colorSpace),
      rawColors: raw,
      isCustom: true
    )
  }

  /// 生成注入 squirrel.custom.yaml 的 preset_color_schemes/<id> 定义
  static func presetDefinition(for id: String) -> [String: Any]? {
    guard let scheme = all.first(where: { $0.id == id }) else { return nil }
    var def: [String: Any] = ["name": scheme.name, "author": scheme.author]
    if scheme.colorSpace.lowercased() == "display_p3" {
      def["color_space"] = "display_p3"
    }
    for (key, value) in scheme.colors where !value.isEmpty {
      def[key] = value
    }
    return def
  }

  /// 从独立 .yaml 片段解析出一套用户方案（用于导入）。
  /// 支持 `preset_color_schemes/<id>: { name/author/...colors }` 形式。
  /// 返回 nil 表示不是可识别的方案文件。
  static func parseImportedYAML(_ text: String) -> UserColorScheme? {
    guard let object = try? Yams.load(yaml: text) as? [String: Any],
          let presets = object["preset_color_schemes"] as? [String: Any] else { return nil }
    // 取第一个方案
    for (id, body) in presets {
      guard let body = body as? [String: Any] else { continue }
      var colors: [String: String] = [:]
      for (key, value) in body where key.hasSuffix("_color") {
        if let s = value as? String, s.lowercased().hasPrefix("0x") {
          colors[key] = s
        } else if let n = value as? Int {
          // 容错：若文件里是十进制（例如被旧版损坏过），尝试还原为 0x 十六进制
          colors[key] = String(format: "0x%06X", n)
        }
      }
      let name = (body["name"] as? String) ?? id
      let author = (body["author"] as? String) ?? ""
      let space = (body["color_space"] as? String) ?? "srgb"
      var scheme = UserColorScheme(id: id, name: name, author: author,
                                   colorSpace: space, colors: colors)
      // 若 id 与既有冲突，追加后缀确保唯一
      if ids.contains(scheme.id) {
        scheme.id = scheme.id + "-" + UUID().uuidString.prefix(4).lowercased()
      }
      return scheme
    }
    return nil
  }
}

// MARK: - 可编辑颜色字段清单

extension UserColorSchemes {
  /// 全部可在编辑器中编辑的颜色键（短名 + 本地化标题键 + 用途描述键）。
  /// 覆盖鼠须管/Squirrel 支持的全部 *_color 键。
  static let colorFields: [(key: String, titleKey: String, descriptionKey: String)] = [
    ("text_color", "scheme.field.text_color", "scheme.field.text_color.description"),
    ("back_color", "scheme.field.back_color", "scheme.field.back_color.description"),
    ("candidate_text_color", "scheme.field.candidate_text_color", "scheme.field.candidate_text_color.description"),
    ("candidate_back_color", "scheme.field.candidate_back_color", "scheme.field.candidate_back_color.description"),
    ("comment_text_color", "scheme.field.comment_text_color", "scheme.field.comment_text_color.description"),
    ("hilited_text_color", "scheme.field.hilited_text_color", "scheme.field.hilited_text_color.description"),
    ("hilited_back_color", "scheme.field.hilited_back_color", "scheme.field.hilited_back_color.description"),
    ("hilited_candidate_text_color", "scheme.field.hilited_candidate_text_color", "scheme.field.hilited_candidate_text_color.description"),
    ("hilited_candidate_back_color", "scheme.field.hilited_candidate_back_color", "scheme.field.hilited_candidate_back_color.description"),
    ("hilited_comment_text_color", "scheme.field.hilited_comment_text_color", "scheme.field.hilited_comment_text_color.description"),
    ("border_color", "scheme.field.border_color", "scheme.field.border_color.description"),
    ("label_color", "scheme.field.label_color", "scheme.field.label_color.description"),
    ("label_back_color", "scheme.field.label_back_color", "scheme.field.label_back_color.description"),
    ("label_candidate_text_color", "scheme.field.label_candidate_text_color", "scheme.field.label_candidate_text_color.description"),
    ("label_candidate_back_color", "scheme.field.label_candidate_back_color", "scheme.field.label_candidate_back_color.description"),
    ("preedit_text_color", "scheme.field.preedit_text_color", "scheme.field.preedit_text_color.description"),
    ("preedit_back_color", "scheme.field.preedit_back_color", "scheme.field.preedit_back_color.description"),
    ("hilited_preedit_text_color", "scheme.field.hilited_preedit_text_color", "scheme.field.hilited_preedit_text_color.description"),
    ("hilited_preedit_back_color", "scheme.field.hilited_preedit_back_color", "scheme.field.hilited_preedit_back_color.description")
  ]
}
