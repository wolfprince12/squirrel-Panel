//
//  SettingsStore.swift
//  Squirrel Panel
//
//  界面状态的唯一数据源。
//
//  工作方式：载入时把补丁文件读成一组界面状态，改动只停留在内存里；
//  点「应用」才编译成补丁键值写回磁盘并触发部署。
//  「有未保存改动」通过比对编译结果与载入时的快照得出，不用手工标脏。
//

import Foundation
import SwiftUI
import Yams

/// 分应用适配的一条记录
struct AppOptionEntry: Identifiable, Equatable {
  var id: String { bundleID }
  var bundleID: String
  var displayName: String
  /// 进入该应用时默认切到英文
  var asciiMode: Bool = false
  /// 在该应用中禁用内嵌编码
  var noInline: Bool = false
  /// 在该应用中强制内嵌编码
  var inline: Bool = false
  /// 失去焦点时自动切回英文（适合 Vim 类编辑器）
  var vimMode: Bool = false

  var isEmpty: Bool { !asciiMode && !noInline && !inline && !vimMode }
}

@MainActor
@Observable
final class SettingsStore {

  // MARK: - 环境

  private(set) var environment: RimeEnvironment
  private(set) var colorSchemes: [RimeColorSchemeInfo] = []
  private(set) var availableSchemas: [RimeSchema] = []

  private var squirrelPatch: CustomYAMLFile
  private var defaultPatch: CustomYAMLFile

  /// 雾凇拼音面板（RimeIceConfigStore）的反向引用，用于在统一的「应用并部署」中
  /// 一并写盘 rime_ice.custom.yaml 与 default.custom.yaml 的 switcher/save_options。
  /// 用 weak 避免与 RimeIceConfigStore 的 unowned settings 形成循环。
  weak var rimeIce: RimeIceConfigStore?

  /// AI 增强引擎面板（AIConfigStore）的反向引用，用于在统一的「应用并部署」中
  /// 一并提交 AI 配置、启停引擎并重新部署。
  weak var aiConfig: AIConfigStore?

  /// 载入时的编译快照，用于判断是否有未应用的改动
  private var baselineSquirrel: PatchSet = [:]
  private var baselineDefault: PatchSet = [:]

  /// 出厂 `default.yaml` 的 `switcher/save_options` 名单（reload 时读一次，缓存）。
  ///
  /// 用于在 `compileDefaultPatch()` 里判定「名单是否与出厂逐项相同」——相同就不落盘。
  /// 只判空不判出厂会让干净安装下的一次「应用」把出厂名单原样快照进
  /// `default.custom.yaml`，上游 rime-ice 日后往 save_options 里加开关时会被这份
  /// 陈旧快照静默压掉（新增开关不再被记忆），与 switches 段是同一个升级冻结雷。
  ///
  /// **只在 reload() → readIntoUI() 里读一次盘**：`compileDefaultPatch()` 挂在
  /// SwiftUI 求值路径上（`isDirty` 每帧调），绝不能在其中做磁盘 I/O。
  private var cachedFactorySaveOptions: Set<String> = []

  // MARK: - 外观

  var colorSchemeID = "native"
  var followSystemAppearance = false
  var colorSchemeDarkID = "native"
  var fontFace = ""
  var labelFontFace = ""
  var commentFontFace = ""
  var fontPoint: Double = 16
  var labelFontPoint: Double = 12
  var commentFontPoint: Double = 12
  var useLinearLayout = false
  var useVerticalText = false
  var cornerRadius: Double = 7
  var hilitedCornerRadius: Double = 4
  var borderHeight: Double = 0
  var borderWidth: Double = 0
  var lineSpacing: Double = 5
  var preeditSpacing: Double = 10
  var alpha: Double = 1
  var candidateFormat = "[label]. [candidate] [comment]"
  var inlinePreedit = true
  var inlineCandidate = false
  var translucency = false
  var shadow = false
  var shadowSize: Double = 0
  var statusMessageType = "mix"
  var showPaging = false
  var memorizeSize = true
  var mutualExclusive = false

  // MARK: - 输入方案

  var enabledSchemaIDs: [String] = []
  var switcherHotkeys = ""
  var switcherCaption = ""
  /// switcher/save_options：哪些开关在方案选单切换后被「记住」。
  /// 由 RimeIceConfigStore 在应用配置时改写；其余面板不碰它。
  var savedSwitchOptions: [String] = []

  // MARK: - 按键与行为

  var pageSize: Int = 5
  var goodOldCapsLock = true
  var capsLockAction = "commit_code"
  var shiftLeftAction = "commit_code"
  var shiftRightAction = "commit_code"
  var controlLeftAction = "noop"
  var controlRightAction = "noop"
  var keyboardLayout = "last"
  var showNotificationsWhen = "appropriate"

  // MARK: - 标点映射（punctuator）
  /// 全角 / 半角标点符号映射，写入 default.custom.yaml 的
  /// punctuator/full_shape 与 punctuator/half_shape。
  var fullShapePunct: [String: Any] = [:]
  var halfShapePunct: [String: Any] = [:]

  // MARK: - 候选窗按键绑定（key_bindings）
  /// 候选窗导航键（确认 / 取消 / 翻页 / 方向等），写入 squirrel.custom.yaml 的 key_bindings
  var candidateKeyBindings: [[String: Any]] = []

  /// Tab 翻页开关：Tab 向后翻页（同 =），Shift+Tab 向前翻页（同 -）
  var tabPagingEnabled = false
  /// 我们是否在托管 key_bindings（载入时已含我们的 Tab 条目，或用户历史上启用过）
  private var managingKeyBindings = false

  // MARK: - 分应用适配

  var appOptions: [AppOptionEntry] = []
  private var originalAppBundleIDs: Set<String> = []

  // MARK: - 运行状态

  var statusMessage = ""
  var lastError: String?
  var isApplying = false

  var isDirty: Bool {
    compileSquirrelPatch() != baselineSquirrel
      || compileDefaultPatch() != baselineDefault
      || rimeIce?.isDirty == true
      || aiConfig?.hasPendingChanges == true
  }

  var canWrite: Bool { squirrelPatch.isWritable && defaultPatch.isWritable }

  var unparsableWarning: String? {
    if case .unparsable(let reason) = squirrelPatch.state {
      return String(format: String(localized: "error.parse.squirrel"), reason)
    }
    if case .unparsable(let reason) = defaultPatch.state {
      return String(format: String(localized: "error.parse.default"), reason)
    }
    return nil
  }

  // MARK: - 生命周期

  init() {
    let env = RimeEnvironment.detect()
    self.environment = env
    self.squirrelPatch = CustomYAMLFile(fileURL: RimeEnvironment.userDirectory.appending(path: "squirrel.custom.yaml"))
    self.defaultPatch = CustomYAMLFile(fileURL: RimeEnvironment.userDirectory.appending(path: "default.custom.yaml"))
    reload()
  }

  func reload() {
    cachedBuiltinStyleDefaults = nil
    environment = RimeEnvironment.detect()
    squirrelPatch.load()
    defaultPatch.load()
    colorSchemes = ColorSchemeCatalog.load(environment: environment, userPatch: squirrelPatch)
    availableSchemas = SchemaCatalog.scan(environment: environment)
    readIntoUI()
    baselineSquirrel = compileSquirrelPatch()
    baselineDefault = compileDefaultPatch()
    statusMessage = environment.isInstalled ? "status.loaded" : "status.notInstalled"
    // 雾凇面板跟着一起重载，保证两边状态一致（应用、还原、重置后都会走到这里）
    rimeIce?.reload()
  }

  // MARK: - 读：补丁 → 界面

  private func readIntoUI() {
    let defaults = builtinStyleDefaults()

    func str(_ key: String, _ fallback: String) -> String {
      squirrelPatch.string(forPath: key) ?? (defaults[key] as? String) ?? fallback
    }
    func num(_ key: String, _ fallback: Double) -> Double {
      if let v = squirrelPatch.double(forPath: key) { return v }
      if let v = defaults[key] as? Int { return Double(v) }
      if let v = defaults[key] as? Double { return v }
      return fallback
    }
    func flag(_ key: String, _ fallback: Bool) -> Bool {
      squirrelPatch.bool(forPath: key) ?? (defaults[key] as? Bool) ?? fallback
    }

    colorSchemeID = str("style/color_scheme", "native")
    if let dark = squirrelPatch.string(forPath: "style/color_scheme_dark") {
      // patch 中有 color_scheme_dark：如果和 color_scheme 相同，说明用户关闭了跟随系统外观
      if dark == colorSchemeID {
        followSystemAppearance = false
        colorSchemeDarkID = colorSchemeID
      } else {
        followSystemAppearance = true
        colorSchemeDarkID = dark
      }
    } else if let dark = defaults["style/color_scheme_dark"] as? String {
      followSystemAppearance = false
      colorSchemeDarkID = dark
    } else {
      followSystemAppearance = false
      colorSchemeDarkID = colorSchemeID
    }

    fontFace = str("style/font_face", "")
    labelFontFace = str("style/label_font_face", "")
    commentFontFace = str("style/comment_font_face", "")
    fontPoint = num("style/font_point", 16)
    labelFontPoint = num("style/label_font_point", max(9, fontPoint - 4))
    commentFontPoint = num("style/comment_font_point", max(9, fontPoint - 4))
    useLinearLayout = str("style/candidate_list_layout", "stacked") == "linear"
    useVerticalText = str("style/text_orientation", "horizontal") == "vertical"
    cornerRadius = num("style/corner_radius", 7)
    hilitedCornerRadius = num("style/hilited_corner_radius", 4)
    borderHeight = num("style/border_height", 0)
    borderWidth = num("style/border_width", 0)
    lineSpacing = num("style/line_spacing", 5)
    preeditSpacing = num("style/spacing", 10)
    alpha = num("style/alpha", 1)
    candidateFormat = str("style/candidate_format", "[label]. [candidate] [comment]")
    inlinePreedit = flag("style/inline_preedit", true)
    inlineCandidate = flag("style/inline_candidate", false)
    translucency = flag("style/translucency", false)
    shadow = flag("style/shadow", false)
    shadowSize = num("style/shadow_size", 0)
    statusMessageType = str("style/status_message_type", "mix")
    showPaging = flag("style/show_paging", false)
    memorizeSize = flag("style/memorize_size", true)
    mutualExclusive = flag("style/mutual_exclusive", false)
    keyboardLayout = squirrelPatch.string(forPath: "keyboard_layout") ?? "last"
    showNotificationsWhen = squirrelPatch.string(forPath: "show_notifications_when") ?? "appropriate"

    fullShapePunct = (defaultPatch.value(forPath: "punctuator/full_shape") as? [String: Any]) ?? [:]
    halfShapePunct = (defaultPatch.value(forPath: "punctuator/half_shape") as? [String: Any]) ?? [:]
    if let list = squirrelPatch.value(forPath: "key_bindings") as? [[String: Any]] {
      candidateKeyBindings = list
    } else if let list = squirrelPatch.value(forPath: "key_bindings") as? [Any] {
      candidateKeyBindings = list.compactMap { $0 as? [String: Any] }
    } else {
      candidateKeyBindings = []
    }

    enabledSchemaIDs = SchemaCatalog.enabledSchemaIDs(patch: defaultPatch, environment: environment)
    switcherHotkeys = readList(defaultPatch, "switcher/hotkeys").joined(separator: ", ")
    switcherCaption = defaultPatch.string(forPath: "switcher/caption") ?? ""
    // switcher/save_options：用户若显式写过（即使为空列表）则尊重之；
    // 否则回落到 default.yaml 出厂默认，避免一上来就把 5 个开关全塞进 save_options。
    //
    // 出厂名单在这里读一次并缓存（整个 reload 周期唯一一次读盘，与下面的回落共用结果），
    // 供 compileDefaultPatch() 判定「与出厂相同 → 不落盘」。
    let factorySaveOptions = defaultSaveOptions()
    cachedFactorySaveOptions = Set(factorySaveOptions)
    if defaultPatch.value(forPath: "switcher/save_options") != nil {
      savedSwitchOptions = readList(defaultPatch, "switcher/save_options")
    } else {
      savedSwitchOptions = factorySaveOptions
    }

    pageSize = defaultPatch.int(forPath: "menu/page_size") ?? readDefaultYAMLInt("menu/page_size") ?? 5
    goodOldCapsLock = defaultPatch.bool(forPath: "ascii_composer/good_old_caps_lock") ?? true
    capsLockAction = defaultPatch.string(forPath: "ascii_composer/switch_key/Caps_Lock") ?? "commit_code"
    shiftLeftAction = defaultPatch.string(forPath: "ascii_composer/switch_key/Shift_L") ?? "commit_code"
    shiftRightAction = defaultPatch.string(forPath: "ascii_composer/switch_key/Shift_R") ?? "commit_code"
    controlLeftAction = defaultPatch.string(forPath: "ascii_composer/switch_key/Control_L") ?? "noop"
    controlRightAction = defaultPatch.string(forPath: "ascii_composer/switch_key/Control_R") ?? "noop"

    let existing = existingTabBindings()
    managingKeyBindings = !existing.isEmpty
    tabPagingEnabled = managingKeyBindings

    readAppOptions()
  }

  private func readList(_ file: CustomYAMLFile, _ path: String) -> [String] {
    if let list = file.value(forPath: path) as? [Any] {
      return list.compactMap { $0 as? String }
    }
    if let text = file.string(forPath: path) {
      return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    return []
  }

  private func readDefaultYAMLInt(_ path: String) -> Int? {
    for url in environment.configSources(named: "default.yaml") {
      guard let text = try? String(contentsOf: url, encoding: .utf8),
            let object = try? Yams.load(yaml: text) as? [String: Any] else { continue }
      var node: Any? = object
      for part in path.split(separator: "/") {
        node = (node as? [String: Any])?[String(part)]
      }
      if let v = node as? Int { return v }
    }
    return nil
  }

  /// 从出厂 default.yaml 读取 switcher/save_options（仅当 default.custom.yaml 没写过时用）
  private func defaultSaveOptions() -> [String] {
    for url in environment.configSources(named: "default.yaml") {
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

  // MARK: - 键位（key_binder/bindings）

  /// 追加到 key_binder/bindings 的两条 Tab 翻页绑定
  /// 使用 has_menu 以匹配用户当前 rime-ice default.yaml 中 minus/equal 的语义
  private static let tabBindings: [[String: Any]] = [
    ["when": "has_menu", "accept": "Tab", "send": "Page_Down"],
    ["when": "has_menu", "accept": "Shift+Tab", "send": "Page_Up"]
  ]
  private static let tabBindingAppendPath = "key_binder/bindings/+"

  /// 判断一条 binding 是否属于我们管理的 Tab 翻页
  private static func isOurTabBinding(_ entry: [String: Any]) -> Bool {
    guard let accept = entry["accept"] as? String,
          let send = entry["send"] as? String else { return false }
    return (accept == "Tab" && send == "Page_Down")
        || (accept == "Shift+Tab" && send == "Page_Up")
  }

  /// 读取 default.custom.yaml 里 key_binder/bindings 与 key_binder/bindings/+ 中的条目
  private func existingTabBindings() -> [[String: Any]] {
    var result: [[String: Any]] = []
    for key in ["key_binder/bindings", "key_binder/bindings/+"] {
      if let list = defaultPatch.value(forPath: key) as? [[String: Any]] {
        result.append(contentsOf: list)
      } else if let list = defaultPatch.value(forPath: key) as? [Any] {
        result.append(contentsOf: list.compactMap { $0 as? [String: Any] })
      }
    }
    return result.filter { Self.isOurTabBinding($0) }
  }

  /// 组装要写入 `key_binder/bindings/+` 的列表：保留用户其它追加条目，去重后加入/移除我们的 Tab 绑定
  private func mergedTabBindingAppendList() -> [[String: Any]] {
    var result: [[String: Any]] = []
    var seen = Set<String>()
    if let plus = defaultPatch.value(forPath: Self.tabBindingAppendPath) as? [[String: Any]] {
      for entry in plus where !Self.isOurTabBinding(entry) {
        if let accept = entry["accept"] as? String { seen.insert(accept) }
        result.append(entry)
      }
    } else if let plus = defaultPatch.value(forPath: Self.tabBindingAppendPath) as? [Any] {
      for entry in plus.compactMap({ $0 as? [String: Any] }) where !Self.isOurTabBinding(entry) {
        if let accept = entry["accept"] as? String { seen.insert(accept) }
        result.append(entry)
      }
    }
    if tabPagingEnabled {
      for entry in Self.tabBindings {
        guard let accept = entry["accept"] as? String else { continue }
        if seen.contains(accept) { continue }
        seen.insert(accept)
        result.append(entry)
      }
    }
    return result
  }

  /// 卸载 / 恢复默认时，仅移除我们的 Tab 条目，保留用户其它追加键位
  private func stripTabBindings() {
    let remaining = mergedTabBindingAppendList().filter { !Self.isOurTabBinding($0) }
    defaultPatch.set(remaining.isEmpty ? nil : remaining, forPath: Self.tabBindingAppendPath)
    managingKeyBindings = false
  }

  /// 内置 squirrel.yaml 里的 style 段默认值，界面上以它为基准显示。
  /// 先读系统 Squirrel.app 中的 squirrel.yaml，再用用户目录的 squirrel.yaml 覆盖，
  /// 确保 put() 优化和 readIntoUI() 的回退值与实际生效配置一致。
  ///
  /// 该结果在 reload() 时缓存，避免 `isDirty` 每次重算都同步读盘 + 解析 YAML——
  /// 此前这段主线程 I/O 正是面板切换 / 控件改动时界面「黏手、延迟」的根因。
  private var cachedBuiltinStyleDefaults: [String: Any]?

  private func builtinStyleDefaults() -> [String: Any] {
    if let cached = cachedBuiltinStyleDefaults { return cached }
    var result: [String: Any] = [:]
    if let object = try? Yams.load(yaml: environment.builtinSquirrelYAML()) as? [String: Any] {
      if let style = object["style"] as? [String: Any] {
        for (key, value) in style { result["style/\(key)"] = value }
      }
    }
    // 用户 squirrel.yaml 覆盖系统默认值
    let userSquirrelYAML = RimeEnvironment.userDirectory.appending(path: "squirrel.yaml")
    if let text = try? String(contentsOf: userSquirrelYAML, encoding: .utf8),
       let object = try? Yams.load(yaml: text) as? [String: Any],
       let style = object["style"] as? [String: Any] {
      for (key, value) in style { result["style/\(key)"] = value }
    }
    cachedBuiltinStyleDefaults = result
    return result
  }

  private func readAppOptions() {
    var entries: [String: AppOptionEntry] = [:]

    func absorb(bundleID: String, option: String, value: Bool) {
      var entry = entries[bundleID] ?? AppOptionEntry(bundleID: bundleID,
                                                      displayName: Self.displayName(for: bundleID))
      switch option {
      case "ascii_mode": entry.asciiMode = value
      case "no_inline": entry.noInline = value
      case "inline": entry.inline = value
      case "vim_mode": entry.vimMode = value
      default: break
      }
      entries[bundleID] = entry
    }

    // 扁平写法：app_options/<bundle>/<option>
    for key in squirrelPatch.topLevelKeys where key.hasPrefix("app_options/") {
      let parts = key.split(separator: "/").map(String.init)
      guard parts.count == 3, let value = squirrelPatch.bool(forPath: key) else { continue }
      absorb(bundleID: parts[1], option: parts[2], value: value)
    }
    // 嵌套写法
    if let nested = squirrelPatch.value(forPath: "app_options") as? [String: Any] {
      for (bundleID, body) in nested {
        guard let body = body as? [String: Any] else { continue }
        for (option, value) in body {
          if let flag = value as? Bool { absorb(bundleID: bundleID, option: option, value: flag) }
        }
      }
    }

    appOptions = entries.values.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    originalAppBundleIDs = Set(entries.keys)
  }

  static func displayName(for bundleID: String) -> String {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
      let name = FileManager.default.displayName(atPath: url.path(percentEncoded: false))
      return name.replacingOccurrences(of: ".app", with: "")
    }
    return bundleID
  }

  // MARK: - 写：界面 → 补丁

  /// 本面板管理的 squirrel.custom.yaml 键，「恢复默认」时只清理这些
  static let managedSquirrelKeys: Set<String> = [
    "style/color_scheme", "style/color_scheme_dark", "style/font_face", "style/font_point",
    "style/label_font_face", "style/label_font_point", "style/comment_font_face", "style/comment_font_point", "style/candidate_list_layout",
    "style/text_orientation", "style/corner_radius", "style/hilited_corner_radius",
    "style/border_height", "style/border_width", "style/line_spacing", "style/spacing",
    "style/alpha", "style/candidate_format", "style/inline_preedit", "style/inline_candidate",
    "style/translucency", "style/show_paging", "style/memorize_size", "style/mutual_exclusive",
    "style/shadow_size", "style/status_message_type",
    "keyboard_layout", "show_notifications_when", "key_bindings"
  ]

  static let managedDefaultKeys: Set<String> = [
    "schema_list", "menu/page_size", "ascii_composer/good_old_caps_lock",
    "ascii_composer/switch_key/Caps_Lock", "ascii_composer/switch_key/Shift_L",
    "ascii_composer/switch_key/Shift_R", "ascii_composer/switch_key/Control_L",
    "ascii_composer/switch_key/Control_R", "switcher/hotkeys", "switcher/caption",
    "punctuator/full_shape", "punctuator/half_shape"
  ]

  func compileSquirrelPatch() -> PatchSet {
    let defaults = builtinStyleDefaults()

    /// 与内置默认值相同的项不写入，保持补丁文件精简
    func put(_ set: inout PatchSet, _ key: String, _ value: PatchValue, defaultValue: Any?) {
      if let defaultValue, isSame(value, defaultValue) {
        set[key] = PatchValue?.none
      } else {
        set[key] = value
      }
    }

    var set: PatchSet = [:]
    put(&set, "style/color_scheme", .string(colorSchemeID), defaultValue: defaults["style/color_scheme"])
    // followSystemAppearance=false 时，显式将 color_scheme_dark 设为与 color_scheme 相同值，
    // 覆盖用户 squirrel.yaml 基础配置中可能存在的 color_scheme_dark，确保明暗模式使用同一配色。
    set["style/color_scheme_dark"] = followSystemAppearance ? .string(colorSchemeDarkID) : .string(colorSchemeID)
    set["style/font_face"] = fontFace.isEmpty ? PatchValue?.none : .string(fontFace)
    set["style/label_font_face"] = labelFontFace.isEmpty ? PatchValue?.none : .string(labelFontFace)
    set["style/comment_font_face"] = commentFontFace.isEmpty ? PatchValue?.none : .string(commentFontFace)
    put(&set, "style/font_point", .double(fontPoint), defaultValue: defaults["style/font_point"])
    put(&set, "style/label_font_point", .double(labelFontPoint), defaultValue: defaults["style/label_font_point"])
    put(&set, "style/comment_font_point", .double(commentFontPoint), defaultValue: defaults["style/comment_font_point"])
    put(&set, "style/candidate_list_layout", .string(useLinearLayout ? "linear" : "stacked"),
        defaultValue: defaults["style/candidate_list_layout"])
    put(&set, "style/text_orientation", .string(useVerticalText ? "vertical" : "horizontal"),
        defaultValue: defaults["style/text_orientation"])
    put(&set, "style/corner_radius", .double(cornerRadius), defaultValue: defaults["style/corner_radius"])
    put(&set, "style/hilited_corner_radius", .double(hilitedCornerRadius), defaultValue: defaults["style/hilited_corner_radius"])
    put(&set, "style/border_height", .double(borderHeight), defaultValue: defaults["style/border_height"])
    put(&set, "style/border_width", .double(borderWidth), defaultValue: defaults["style/border_width"])
    put(&set, "style/line_spacing", .double(lineSpacing), defaultValue: defaults["style/line_spacing"])
    put(&set, "style/spacing", .double(preeditSpacing), defaultValue: defaults["style/spacing"])
    put(&set, "style/alpha", .double(alpha), defaultValue: defaults["style/alpha"])
    // 候选格式保护：若用户输入不包含候选词占位符（[candidate] 或 %@），
    // 鼠须管会把所有候选渲染成同一固定字符串，导致输入法"假死"。
    // 此处强制回退到安全默认值，杜绝破坏性写入。
    let safeCandidateFormat = candidateFormat.contains("[candidate]") || candidateFormat.contains("%@")
      ? candidateFormat
      : "[label]. [candidate] [comment]"
    put(&set, "style/candidate_format", .string(safeCandidateFormat), defaultValue: defaults["style/candidate_format"])
    put(&set, "style/inline_preedit", .bool(inlinePreedit), defaultValue: defaults["style/inline_preedit"])
    put(&set, "style/inline_candidate", .bool(inlineCandidate), defaultValue: defaults["style/inline_candidate"])
    put(&set, "style/translucency", .bool(translucency), defaultValue: defaults["style/translucency"])
    // 阴影：仅当用户开启时才写入，关闭时回落出厂（不落盘）
    set["style/shadow"] = shadow ? .bool(true) : PatchValue?.none
    // 阴影大小：出厂默认 0（不渲染阴影），与默认相同不落盘
    put(&set, "style/shadow_size", .double(shadowSize), defaultValue: defaults["style/shadow_size"] ?? 0)
    // 状态提示类型：出厂 yaml 无此键（Squirrel 默认 mix），等于默认值不落盘
    set["style/status_message_type"] = statusMessageType == "mix" ? PatchValue?.none : .string(statusMessageType)
    put(&set, "style/show_paging", .bool(showPaging), defaultValue: defaults["style/show_paging"])
    put(&set, "style/memorize_size", .bool(memorizeSize), defaultValue: defaults["style/memorize_size"])
    put(&set, "style/mutual_exclusive", .bool(mutualExclusive), defaultValue: defaults["style/mutual_exclusive"])
    set["keyboard_layout"] = keyboardLayout == "last" ? PatchValue?.none : .string(keyboardLayout)
    set["show_notifications_when"] = showNotificationsWhen == "appropriate" ? PatchValue?.none : .string(showNotificationsWhen)
    // 候选窗按键绑定：列表为空则不落盘（回落出厂 squirrel.yaml）
    set["key_bindings"] = candidateKeyBindings.isEmpty ? PatchValue?.none : .keyBindings(candidateKeyBindings)

    for entry in appOptions {
      let prefix = "app_options/\(entry.bundleID)"
      set["\(prefix)/ascii_mode"] = entry.asciiMode ? .bool(true) : PatchValue?.none
      set["\(prefix)/no_inline"] = entry.noInline ? .bool(true) : PatchValue?.none
      set["\(prefix)/inline"] = entry.inline ? .bool(true) : PatchValue?.none
      set["\(prefix)/vim_mode"] = entry.vimMode ? .bool(true) : PatchValue?.none
    }
    // 用户删掉的条目要显式清除
    for bundleID in originalAppBundleIDs where !appOptions.contains(where: { $0.bundleID == bundleID }) {
      for option in ["ascii_mode", "no_inline", "inline", "vim_mode"] {
        set["app_options/\(bundleID)/\(option)"] = PatchValue?.none
      }
    }
    return set
  }

  func compileDefaultPatch() -> PatchSet {
    var set: PatchSet = [:]
    set["schema_list"] = enabledSchemaIDs.isEmpty ? PatchValue?.none : .schemaList(enabledSchemaIDs)
    set["menu/page_size"] = .int(pageSize)
    set["ascii_composer/good_old_caps_lock"] = .bool(goodOldCapsLock)
    set["ascii_composer/switch_key/Caps_Lock"] = .string(capsLockAction)
    set["ascii_composer/switch_key/Shift_L"] = .string(shiftLeftAction)
    set["ascii_composer/switch_key/Shift_R"] = .string(shiftRightAction)
    set["ascii_composer/switch_key/Control_L"] = .string(controlLeftAction)
    set["ascii_composer/switch_key/Control_R"] = .string(controlRightAction)
    let hotkeys = switcherHotkeys.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    set["switcher/hotkeys"] = hotkeys.isEmpty ? PatchValue?.none : .stringList(hotkeys)
    set["switcher/caption"] = switcherCaption.isEmpty ? PatchValue?.none : .string(switcherCaption)
    // 标点映射表：全角 / 半角符号表，字典为空则不落盘
    set["punctuator/full_shape"] = fullShapePunct.isEmpty ? PatchValue?.none : .punctuation(fullShapePunct)
    set["punctuator/half_shape"] = halfShapePunct.isEmpty ? PatchValue?.none : .punctuation(halfShapePunct)
    // switcher/save_options：由 RimeIceConfigStore 在应用雾凇配置时改写；
    // 与 switches 的 reset 互斥——记住的开关不能带 reset。
    //
    // 与出厂 default.yaml 逐项相同的名单一律不落盘（同 switches 段的铁律）：
    // 只判空不判出厂时，用户在任意面板点一次「应用」就会把出厂名单快照进
    // default.custom.yaml，上游日后增删 save_options 会被这份陈旧快照静默压掉。
    // Rime 的 save_options 是集合语义（只做 contains 判定），比较时忽略顺序。
    //
    // 名单为空 → 同样写 nil 回落出厂：这是「6 个开关全设成固定默认」的既有设计，
    // 此时 rime_ice.custom.yaml 的 switches 段带 reset，会压过 default 的记忆名单。
    let saveOptions = savedSwitchOptions
    let matchesFactory = Set(saveOptions) == cachedFactorySaveOptions
    set["switcher/save_options"] = (saveOptions.isEmpty || matchesFactory)
      ? PatchValue?.none
      : .stringList(saveOptions)
    // Tab 翻页通过 key_binder/bindings/+ 追加到现有键位列表；启用时追加，关闭时移除我们的条目
    if managingKeyBindings || tabPagingEnabled {
      let appendList = mergedTabBindingAppendList()
      if appendList.isEmpty {
        set[Self.tabBindingAppendPath] = PatchValue?.none
      } else {
        set[Self.tabBindingAppendPath] = .keyBindings(appendList)
      }
    }
    return set
  }

  private func isSame(_ value: PatchValue, _ other: Any) -> Bool {
    switch value {
    case .bool(let v): return (other as? Bool) == v
    case .int(let v): return (other as? Int) == v
    case .double(let v):
      if let i = other as? Int { return Double(i) == v }
      if let d = other as? Double { return d == v }
      return false
    case .string(let v): return (other as? String) == v
    default: return false
    }
  }

  // MARK: - 应用

  func apply() {
    guard canWrite, rimeIce?.canWrite ?? true, aiConfig?.canWrite ?? true else {
      lastError = unparsableWarning ?? rimeIce?.unparsableWarning
      return
    }
    isApplying = true
    lastError = nil
    statusMessage = "status.saving"

    // 写盘与部署涉及外部进程（Squirrel CLI / launchctl / Agent），
    // 在主线程同步等待会导致界面未响应。整体放到后台执行，完成后回主线程更新状态。
    Task { @MainActor in
      defer { self.isApplying = false }
      do {
        // 若雾凇拼音面板有未保存改动，先把 save_options 同步进本面板编译结果，
        // 并写盘 rime_ice.custom.yaml（统一一次部署，自动继承 v1.1.4 源文件预检）。
        self.rimeIce?.contribute(to: self)
        try self.rimeIce?.writePatch()
        let squirrelSet = self.compileSquirrelPatch()
        let defaultSet = self.compileDefaultPatch()
        for (key, value) in squirrelSet { self.squirrelPatch.set(value?.yamlObject, forPath: key) }
        for (key, value) in defaultSet { self.defaultPatch.set(value?.yamlObject, forPath: key) }
        // 开发者（大狼）专属配色与用户自定义配色：把当前正在使用的方案定义注入
        // squirrel.custom.yaml 的 preset_color_schemes/<id>，让鼠须管能解析并实际渲染；
        // 未使用的方案定义则清理，保持补丁干净、避免无用的孤立预设。
        var activeDevIDs = Set([self.colorSchemeID])
        if self.followSystemAppearance {
          activeDevIDs.insert(self.colorSchemeDarkID)
        }
        activeDevIDs.formIntersection(DeveloperColorSchemes.ids)
        let customIDs = UserColorSchemes.ids
        let allowedPresetIDs = activeDevIDs.union(customIDs)
        // 清理 preset_color_schemes 残留：用户可能用扁平写法（preset_color_schemes/<id>）
        // 或嵌套写法，两种都要扫描；只保留当前激活的开发者/用户方案，其余全部摘除。
        let presetPrefix = "preset_color_schemes/"
        var existingPresetIDs = Set<String>()
        if let nested = self.squirrelPatch.value(forPath: "preset_color_schemes") as? [String: Any] {
          existingPresetIDs.formUnion(nested.keys)
        }
        for key in self.squirrelPatch.topLevelKeys where key.hasPrefix(presetPrefix) {
          let id = String(key.dropFirst(presetPrefix.count))
          if !id.isEmpty { existingPresetIDs.insert(id) }
        }
        for id in existingPresetIDs where !allowedPresetIDs.contains(id) {
          self.squirrelPatch.set(nil, forPath: "preset_color_schemes/\(id)")
        }
        for id in activeDevIDs {
          if let def = DeveloperColorSchemes.presetDefinition(for: id) {
            self.squirrelPatch.set(def, forPath: "preset_color_schemes/\(id)")
          }
        }
        for id in customIDs {
          if let def = UserColorSchemes.presetDefinition(for: id) {
            self.squirrelPatch.set(def, forPath: "preset_color_schemes/\(id)")
          }
        }
        UserColorSchemes.managedIDs = customIDs
        try self.squirrelPatch.save()
        try self.defaultPatch.save()
        self.baselineSquirrel = squirrelSet
        self.baselineDefault = defaultSet
        // 应用成功后，把托管状态同步为当前开关状态，确保用户立刻再次切换时逻辑正确
        self.managingKeyBindings = self.tabPagingEnabled

        // 提交 AI 增强引擎页的 pending 改动（UserDefaults、运行时配置）。
        // 引擎开关与纠错开关已独立即时生效，不在这里启停引擎。
        self.aiConfig?.applyPendingChanges()

        if self.environment.isInstalled {
          self.statusMessage = "status.deploying"
          do {
            // 部署会触发 Squirrel 完整重建方案（含 Lua VM 重载），耗时数秒；
            // 用 deployAsync 真正挂起，让主线程在等待期间保持响应，
            // 修复「应用并重新部署」程序未响应（原来在 @MainActor Task 内同步
            // waitUntilExit 会占满 UI 线程）。部署完成后 Rime 重载 Lua 叠加层，
            // 使 aienergy_config.lua 里的候选槽位等配置真正生效。
            try await SquirrelBridge.deployAsync(environment: self.environment)
            // SquirrelReloadNotification 会触发 Squirrel 的 deploy() → loadSettings()，
            // 完整重读 squirrel.yaml（含配色方案）并应用到 UI 面板。
            // 不需要 restart()——在通知被处理前杀掉 Squirrel 反而会导致配置不生效。
            self.statusMessage = "status.deployed"
          } catch let e as PanelError {
            // 防事故：部署前发现方案源文件缺失，SquirrelBridge.deploy 已中止部署。
            // 配置已写入磁盘，仅暂停重建方案，避免把输入法打挂。
            self.lastError = e.localizedDescription
            self.statusMessage = "status.deploySkipped"
            return
          }
        } else {
          self.statusMessage = "status.savedWithoutSquirrel"
        }
      } catch {
        self.lastError = error.localizedDescription
        self.statusMessage = "status.writeFailed"
      }
    }
  }

  func revert() {
    aiConfig?.discardPendingChanges()
    reload()
    statusMessage = "status.reverted"
  }

  /// 移除本面板写入的全部配置项，保留用户手写的其他条目
  func resetManagedSettings() {
    guard canWrite else { return }
    squirrelPatch.removeManaged(keys: Self.managedSquirrelKeys)
    for bundleID in originalAppBundleIDs {
      squirrelPatch.removeAll(withPrefix: "app_options/\(bundleID)")
    }
    defaultPatch.removeManaged(keys: Self.managedDefaultKeys)
    stripTabBindings()
    do {
      try squirrelPatch.save()
      try defaultPatch.save()
      reload()
      if environment.isInstalled {
        do {
          try SquirrelBridge.deploy(environment: environment)
        } catch let e as PanelError {
          // 清空管理项时若检测到方案源文件缺失，暂停部署并提示，但不阻断重置完成
          lastError = e.localizedDescription
        }
      }
      statusMessage = "status.reset"
    } catch {
      lastError = error.localizedDescription
    }
  }

  /// 恢复鼠须管默认设置：删除所有 *.custom.yaml 文件，让鼠须管完全回到初始状态。
  /// 与 resetManagedSettings 不同，这会移除所有补丁（包括用户手写的），是彻底重置。
  func resetSquirrelDefaults() {
    let fm = FileManager.default
    let dir = RimeEnvironment.userDirectory
    // 列出所有 .custom.yaml 文件
    guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
      lastError = String(localized: "error.squirrelNotInstalled")
      return
    }
    let customFiles = items.filter { $0.pathExtension == "yaml" && $0.lastPathComponent.hasSuffix(".custom.yaml") }
    // 先备份再删除
    for file in customFiles {
      let backup = file.appendingPathExtension("bak")
      try? fm.removeItem(at: backup)
      try? fm.copyItem(at: file, to: backup)
      try? fm.removeItem(at: file)
    }
    reload()
    if environment.isInstalled {
      try? SquirrelBridge.deploy(environment: environment)
    }
    statusMessage = "status.squirrelReset"
  }

  // MARK: - 修复配置缩进空白

  /// 修复配置文件因「特殊空格 / 非 ASCII 缩进」(典型如 U+2005) 导致解析失败、面板整体只读的问题。
  /// 仅把行首缩进处的特殊空格替换为普通空格，绝不改动值内容（例如 candidate_format 里的 U+2005）。
  /// 对受影响的文件先生成 .bak 备份，再原地写回归一化后的文本；修复完成后重载，面板恢复可写。
  func fixWhitespaceInConfigFiles() {
    let fm = FileManager.default
    let dir = RimeEnvironment.userDirectory
    guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
      lastError = String(localized: "error.squirrelNotInstalled")
      return
    }
    let customFiles = items.filter { $0.pathExtension == "yaml" && $0.lastPathComponent.hasSuffix(".custom.yaml") }
    var fixedCount = 0
    for file in customFiles {
      if Self.normalizeWhitespaceInFile(at: file) { fixedCount += 1 }
    }
    reload()
    statusMessage = fixedCount > 0 ? "status.whitespaceFixed" : "status.whitespaceNone"
  }

  /// 将单个文件行首缩进的特殊空格归一化为普通空格。没有变动则返回 false。
  private static func normalizeWhitespaceInFile(at url: URL) -> Bool {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path(percentEncoded: false)) else { return false }
    guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return false }
    let normalized = CustomYAMLFile.normalizeIndentation(raw)
    guard normalized != raw else { return false }
    let backup = url.appendingPathExtension("bak")
    try? fm.removeItem(at: backup)
    try? fm.copyItem(at: url, to: backup)
    try? normalized.write(to: url, atomically: true, encoding: .utf8)
    return true
  }

  // MARK: - 预览

  /// 生成即将写入磁盘的两份文件内容，供界面上的 YAML 预览使用
  func previewYAML() -> (squirrel: String, defaults: String) {
    let squirrelCopy = CustomYAMLFile(fileURL: squirrelPatch.fileURL)
    let defaultCopy = CustomYAMLFile(fileURL: defaultPatch.fileURL)
    for (key, value) in compileSquirrelPatch() { squirrelCopy.set(value?.yamlObject, forPath: key) }
    for (key, value) in compileDefaultPatch() { defaultCopy.set(value?.yamlObject, forPath: key) }
    return ((try? squirrelCopy.serialize()) ?? String(localized: "yaml.unavailable"),
            (try? defaultCopy.serialize()) ?? String(localized: "yaml.unavailable"))
  }

  var currentScheme: RimeColorSchemeInfo {
    // 开发者（大狼）专属方案与用户自定义方案都不在总目录 colorSchemes 中，
    // 需单独解析；否则选中时回退为 .native，顶部预览与实际配色不符。
    if let dev = DeveloperColorSchemes.all.first(where: { $0.id == colorSchemeID }) {
      return DeveloperColorSchemes.info(for: dev)
    }
    if let custom = UserColorSchemes.all.first(where: { $0.id == colorSchemeID }) {
      return UserColorSchemes.info(for: custom)
    }
    return colorSchemes.first { $0.id == colorSchemeID } ?? .native
  }
}
