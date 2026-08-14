//
//  DeveloperColorSchemes.swift
//  Squirrel Panel
//
//  开发者（大狼）专属签名配色方案。
//  作为 App 内置资源随包发布，在「外观」页的专属模块中展示并可直接套用；
//  不混入总色卡网格，也不依赖用户手写 YAML。
//  选中时由 SettingsStore 把方案定义注入 squirrel.custom.yaml 的
//  preset_color_schemes/<id>，让鼠须管能实际解析并渲染。
//
//  三套皮肤均基于鼠须管系统默认配色方案（aqua：text 0x606060 / back 0xEEECEC /
//  candidate_text 0x000000 / hilited_candidate_back 0xee_fa_3a_0a / comment 0x5a5a5a）
//  修改而来，颜色值为 Rime 的 BGR 倒序十六进制字面量（0xBBGGRR）。
//
//  重要：方案数据来自 Resources/DeveloperColorSchemes.json（运行时读取）。
//  早期版本曾把三套方案写成 DeveloperColorSchemes.swift 里的 static let 数组，
//  但 Swift 发布构建（-O + 全模块优化）会对其做常量折叠 + 死代码消除，
//  把未被“直接独立引用”的元素（daylight / gentle）连同字符串整段删除，
//  导致运行时只剩 latenight 一套。外置为 JSON 资源后，数据由文件读取，
//  优化器无法消除，三套方案必定同时存在。

import Foundation

/// 一套开发者专属配色（与 DeveloperColorSchemes.json 的条目结构对应）
struct DeveloperScheme: Identifiable, Codable {
  let id: String
  let name: String
  let author: String
  /// 原始颜色字段，值为 Rime 的 BGR 倒序十六进制字面量（如 "0x34221C"）
  let colors: [String: String]
}

enum DeveloperColorSchemes {
  /// 全部开发者方案（即「属于我开发的配色方案」专属模块内容）
  /// 从 App 内置 JSON 资源读取，优化器无法消除，三套必同时存在。
  static let all: [DeveloperScheme] = load()

  /// 所有开发者方案 id（用于总网格过滤、注入清理）
  static let ids: Set<String> = Set(all.map { $0.id })

  /// 构造 RimeColorSchemeInfo 供色卡预览渲染
  static func info(for scheme: DeveloperScheme) -> RimeColorSchemeInfo {
    var raw: [String: RimeColor] = [:]
    for (key, value) in scheme.colors {
      if let c = RimeColor(yamlValue: value) { raw[key] = c }
    }
    return RimeColorSchemeInfo(
      id: scheme.id,
      name: scheme.name,
      author: scheme.author,
      colorSpace: .sRGB,
      rawColors: raw,
      isCustom: false
    )
  }

  /// 生成注入 squirrel.custom.yaml 的 preset_color_schemes/<id> 定义
  static func presetDefinition(for id: String) -> [String: Any]? {
    guard let scheme = all.first(where: { $0.id == id }) else { return nil }
    var def: [String: Any] = ["name": scheme.name, "author": scheme.author]
    for (key, value) in scheme.colors { def[key] = value }
    return def
  }

  // MARK: - 资源加载

  private static func load() -> [DeveloperScheme] {
    guard let url = Bundle.main.url(forResource: "DeveloperColorSchemes", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let list = try? JSONDecoder().decode([DeveloperScheme].self, from: data) else {
      // 资源缺失不应崩溃（测试宿主包不含该资源，会走到这里）。
      // App 包内资源始终存在，仅 debug 下提示，避免静默吞掉真实问题。
      #if DEBUG
      print("[DeveloperColorSchemes] 警告：DeveloperColorSchemes.json 缺失或格式错误，已返回空列表")
      #endif
      return []
    }
    return list
  }
}
