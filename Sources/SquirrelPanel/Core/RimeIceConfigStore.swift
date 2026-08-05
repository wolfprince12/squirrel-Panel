//
//  RimeIceConfigStore.swift
//  Squirrel Panel
//
//  雾凇拼音 (rime-ice) 专属配置的唯一数据源。
//
//  设计铁律（见实现计划第二节）：
//  1. 本类**独占** `rime_ice.custom.yaml`，绝不直接 save() `default.custom.yaml`。
//  2. 凡是必须落到 `default.custom.yaml` 的（当前仅 `switcher/save_options`），
//     一律改写 `SettingsStore` 的 @Published 属性，最后由 `settings.apply()` 统一落盘 + 部署。
//  3. `switches` 是列表不是映射，采用「读出厂模板 → 改托管项 reset → 整段写回」。
//  4. `reset`（固定默认）与 `save_options`（开关记忆）互斥：设固定默认时把该项从 save_options 摘除。
//

import Foundation
import SwiftUI
import Yams

/// 三态开关模式：
/// - remember：开关进入 `switcher/save_options`，方案切换后记住上次状态（rime-ice 出厂默认行为）
/// - on：固定开启，整段重写时写 `reset: 1`，且从 save_options 摘除
/// - off：固定关闭，整段重写时写 `reset: 0`，且从 save_options 摘除
enum SwitchDefaultMode: String, CaseIterable, Identifiable {
  var id: String { rawValue }
  case remember = "remember"
  case on = "on"
  case off = "off"
}

/// 出厂模板中的单个 switch（从 rime_ice.schema.yaml 解析，只读）
private struct RimeIceSwitchTemplate {
  let name: String
  let states: [String]
  let abbrev: [String]?
  /// 出厂默认 reset（源文件没写则为 0）
  let factoryReset: Int
}

/// 界面上的一个 switch 行
struct RimeIceSwitchItem: Identifiable {
  var id: String { name }
  let name: String
  let states: [String]
  let abbrev: [String]?
  var mode: SwitchDefaultMode
}

@MainActor
final class RimeIceConfigStore: ObservableObject {

  /// SettingsStore 是 default.custom.yaml 的唯一通道；用 unowned 避免与 store.rimeIce 形成强引用环。
  unowned let settings: SettingsStore

  private var icePatch: CustomYAMLFile
  private var baselineIce: PatchSet = [:]

  /// 出厂模板（reload 时从 rime_ice.schema.yaml 读一次，缓存）
  private var templates: [RimeIceSwitchTemplate] = []

  // MARK: - UI 状态

  @Published var switches: [RimeIceSwitchItem] = []
  @Published var menuPageSize: Int = 5

  // MARK: - 本类托管的 rime_ice.custom.yaml 键（「恢复默认」只清理这些）

  static let managedIceKeys: Set<String> = [
    "switches", "menu/page_size", "traditionalize/opencc_config",
    "engine/translators", "engine/filters", "schema/dependencies", "speller/algebra"
  ]

  // MARK: - 生命周期

  init(settings: SettingsStore) {
    self.settings = settings
    self.icePatch = CustomYAMLFile(fileURL: RimeEnvironment.userDirectory.appending(path: "rime_ice.custom.yaml"))
    reload()
  }

  /// 雾凇拼音方案（rime_ice.schema.yaml）已安装才启用配置区，否则整段置灰
  var isInstalled: Bool { !templates.isEmpty }

  var canWrite: Bool { icePatch.isWritable }

  var unparsableWarning: String? {
    if case .unparsable(let reason) = icePatch.state {
      return String(format: String(localized: "error.parse.riceice"), reason)
    }
    return nil
  }

  func reload() {
    templates = Self.parseTemplates()
    icePatch.load()

    guard isInstalled else {
      switches = []
      menuPageSize = 5
      baselineIce = [:]
      return
    }

    // 当前 rime_ice.custom.yaml 里已重写的 switch reset 值
    let currentSwitches = (icePatch.value(forPath: "switches") as? [[String: Any]]) ?? []
    let currentReset: [String: Int] = Dictionary(uniqueKeysWithValues: currentSwitches.compactMap { item -> (String, Int)? in
      guard let name = item["name"] as? String else { return nil }
      return (name, (item["reset"] as? Int) ?? 0)
    })

    // 记忆名单（来自 default.custom.yaml 的 save_options，经 SettingsStore 读取）
    let saved = Set(settings.savedSwitchOptions)

    switches = templates.map { t in
      let mode: SwitchDefaultMode
      if saved.contains(t.name) {
        mode = .remember
      } else if let r = currentReset[t.name] {
        mode = (r == 1) ? .on : .off
      } else {
        mode = (t.factoryReset == 1) ? .on : .off
      }
      return RimeIceSwitchItem(name: t.name, states: t.states, abbrev: t.abbrev, mode: mode)
    }

    menuPageSize = icePatch.int(forPath: "menu/page_size") ?? 5

    baselineIce = compileIcePatch()
  }

  // MARK: - 读出厂模板

  /// 从 rime_ice.schema.yaml 解析 switches（优先非 build/ 的源文件，避免反馈环）
  private static func parseTemplates() -> [RimeIceSwitchTemplate] {
    let env = RimeEnvironment.detect()
    let urls = env.configSources(named: "rime_ice.schema.yaml")
    guard let url = urls.first(where: { !$0.pathComponents.contains("build") }) ?? urls.first,
          let text = try? String(contentsOf: url, encoding: .utf8),
          let object = try? Yams.load(yaml: text) as? [String: Any],
          let list = object["switches"] as? [[String: Any]] else { return [] }

    return list.compactMap { item -> RimeIceSwitchTemplate? in
      guard let name = item["name"] as? String else { return nil }
      let states = (item["states"] as? [Any])?.compactMap { "\($0)" } ?? []
      let abbrev = (item["abbrev"] as? [Any])?.compactMap { "\($0)" }
      let reset = (item["reset"] as? Int) ?? 0
      return RimeIceSwitchTemplate(name: name, states: states, abbrev: abbrev, factoryReset: reset)
    }
  }

  // MARK: - 写：界面 → 补丁

  /// 编译本面板要写入 rime_ice.custom.yaml 的补丁集合。
  /// 与出厂一致的项写 nil（落回出厂默认），保持补丁文件精简。
  func compileIcePatch() -> PatchSet {
    guard isInstalled else { return [:] }
    var set: PatchSet = [:]

    // switches 整段重写：保留 name / states / abbrev，按三态填 reset
    let list: [[String: Any]] = switches.map { s in
      var dict: [String: Any] = ["name": s.name, "states": s.states]
      if let abbrev = s.abbrev { dict["abbrev"] = abbrev }
      switch s.mode {
      case .remember:
        // 在 save_options 中被记住，reset 被忽略，不写
        break
      case .on:
        dict["reset"] = 1
      case .off:
        dict["reset"] = 0
      }
      return dict
    }
    set["switches"] = .mapList(list)

    // 候选词数：方案级覆盖全局；与出厂默认 5 相同则回落（不写）
    set["menu/page_size"] = (menuPageSize == 5) ? PatchValue?.none : .int(menuPageSize)

    return set
  }

  /// 由 SettingsStore.apply() 在统一落盘前调用：把「记忆」开关名同步进 save_options
  func contribute(to settings: SettingsStore) {
    guard isInstalled else { return }
    let remember = switches.filter { $0.mode == .remember }.map { $0.name }
    settings.savedSwitchOptions = remember
  }

  /// 把本面板编译结果写盘（自带 .bak + unparsable 拒写），并更新基线
  func writePatch() throws {
    guard isInstalled, icePatch.isWritable else { return }
    let set = compileIcePatch()
    for (key, value) in set { icePatch.set(value?.yamlObject, forPath: key) }
    try icePatch.save()
    baselineIce = set
  }

  /// 雾凇面板自身的脏值判断
  var isDirty: Bool {
    guard isInstalled else { return false }
    return compileIcePatch() != baselineIce
  }

  // MARK: - 恢复默认

  /// 把本面板管理的配置全部回到出厂默认：UI 状态回出厂、save_options 回落出厂，
  /// 最后统一走 settings.apply() 一次落盘 + 部署（写盘逻辑集中在 apply → writePatch）。
  func resetManagedRimeIce() {
    guard isInstalled else { return }
    // 1. UI 状态回出厂
    switches = templates.map { t in
      let mode: SwitchDefaultMode = (t.factoryReset == 1) ? .on : .off
      return RimeIceSwitchItem(name: t.name, states: t.states, abbrev: t.abbrev, mode: mode)
    }
    menuPageSize = 5
    // 2. save_options 回落出厂（由 settings.apply 统一写入 default.custom.yaml）
    settings.savedSwitchOptions = factorySaveOptions()
    // 3. 统一落盘 + 部署（apply 内部会写 ice 补丁与 default 补丁，并触发 deploy）
    settings.apply()
  }

  /// 从出厂 default.yaml 读取 switcher/save_options
  private func factorySaveOptions() -> [String] {
    for url in settings.environment.configSources(named: "default.yaml") {
      guard let text = try? String(contentsOf: url, encoding: .utf8),
            let object = try? Yams.load(yaml: text) as? [String: Any] else { continue }
      var node: Any? = object
      for part in "switcher/save_options".split(separator: "/") {
        node = (node as? [String: Any])?[String(part)]
      }
      if let list = node as? [Any] {
        return list.compactMap { $0 as? String }
      }
    }
    return []
  }
}
