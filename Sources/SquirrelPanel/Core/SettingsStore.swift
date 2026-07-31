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
final class SettingsStore: ObservableObject {

  // MARK: - 环境

  @Published private(set) var environment: RimeEnvironment
  @Published private(set) var colorSchemes: [RimeColorSchemeInfo] = []
  @Published private(set) var availableSchemas: [RimeSchema] = []

  private var squirrelPatch: CustomYAMLFile
  private var defaultPatch: CustomYAMLFile

  /// 载入时的编译快照，用于判断是否有未应用的改动
  private var baselineSquirrel: PatchSet = [:]
  private var baselineDefault: PatchSet = [:]

  // MARK: - 外观

  @Published var colorSchemeID = "native"
  @Published var followSystemAppearance = false
  @Published var colorSchemeDarkID = "native"
  @Published var fontFace = ""
  @Published var fontPoint: Double = 16
  @Published var labelFontPoint: Double = 12
  @Published var commentFontPoint: Double = 12
  @Published var useLinearLayout = false
  @Published var useVerticalText = false
  @Published var cornerRadius: Double = 7
  @Published var hilitedCornerRadius: Double = 4
  @Published var borderHeight: Double = 0
  @Published var borderWidth: Double = 0
  @Published var lineSpacing: Double = 5
  @Published var preeditSpacing: Double = 10
  @Published var alpha: Double = 1
  @Published var candidateFormat = "[label]. [candidate] [comment]"
  @Published var inlinePreedit = true
  @Published var inlineCandidate = false
  @Published var translucency = false
  @Published var showPaging = false
  @Published var memorizeSize = true
  @Published var mutualExclusive = false

  // MARK: - 输入方案

  @Published var enabledSchemaIDs: [String] = []
  @Published var switcherHotkeys = ""
  @Published var switcherCaption = ""

  // MARK: - 按键与行为

  @Published var pageSize: Int = 5
  @Published var goodOldCapsLock = true
  @Published var capsLockAction = "commit_code"
  @Published var shiftLeftAction = "commit_code"
  @Published var shiftRightAction = "commit_code"
  @Published var controlLeftAction = "noop"
  @Published var controlRightAction = "noop"
  @Published var keyboardLayout = "last"
  @Published var showNotificationsWhen = "appropriate"

  // MARK: - 分应用适配

  @Published var appOptions: [AppOptionEntry] = []
  private var originalAppBundleIDs: Set<String> = []

  // MARK: - 运行状态

  @Published var statusMessage = ""
  @Published var lastError: String?
  @Published var isApplying = false

  var isDirty: Bool {
    compileSquirrelPatch() != baselineSquirrel || compileDefaultPatch() != baselineDefault
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
    environment = RimeEnvironment.detect()
    squirrelPatch.load()
    defaultPatch.load()
    colorSchemes = ColorSchemeCatalog.load(environment: environment, userPatch: squirrelPatch)
    availableSchemas = SchemaCatalog.scan(environment: environment)
    readIntoUI()
    baselineSquirrel = compileSquirrelPatch()
    baselineDefault = compileDefaultPatch()
    statusMessage = environment.isInstalled ? "status.loaded" : "status.notInstalled"
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
      followSystemAppearance = true
      colorSchemeDarkID = dark
    } else if let dark = defaults["style/color_scheme_dark"] as? String {
      followSystemAppearance = false
      colorSchemeDarkID = dark
    } else {
      followSystemAppearance = false
      colorSchemeDarkID = colorSchemeID
    }

    fontFace = str("style/font_face", "")
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
    showPaging = flag("style/show_paging", false)
    memorizeSize = flag("style/memorize_size", true)
    mutualExclusive = flag("style/mutual_exclusive", false)
    keyboardLayout = squirrelPatch.string(forPath: "keyboard_layout") ?? "last"
    showNotificationsWhen = squirrelPatch.string(forPath: "show_notifications_when") ?? "appropriate"

    enabledSchemaIDs = SchemaCatalog.enabledSchemaIDs(patch: defaultPatch, environment: environment)
    switcherHotkeys = readList(defaultPatch, "switcher/hotkeys").joined(separator: ", ")
    switcherCaption = defaultPatch.string(forPath: "switcher/caption") ?? ""

    pageSize = defaultPatch.int(forPath: "menu/page_size") ?? readDefaultYAMLInt("menu/page_size") ?? 5
    goodOldCapsLock = defaultPatch.bool(forPath: "ascii_composer/good_old_caps_lock") ?? true
    capsLockAction = defaultPatch.string(forPath: "ascii_composer/switch_key/Caps_Lock") ?? "commit_code"
    shiftLeftAction = defaultPatch.string(forPath: "ascii_composer/switch_key/Shift_L") ?? "commit_code"
    shiftRightAction = defaultPatch.string(forPath: "ascii_composer/switch_key/Shift_R") ?? "commit_code"
    controlLeftAction = defaultPatch.string(forPath: "ascii_composer/switch_key/Control_L") ?? "noop"
    controlRightAction = defaultPatch.string(forPath: "ascii_composer/switch_key/Control_R") ?? "noop"

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

  /// 内置 squirrel.yaml 里的 style 段默认值，界面上以它为基准显示
  private func builtinStyleDefaults() -> [String: Any] {
    guard let object = try? Yams.load(yaml: environment.builtinSquirrelYAML()) as? [String: Any] else { return [:] }
    var result: [String: Any] = [:]
    if let style = object["style"] as? [String: Any] {
      for (key, value) in style { result["style/\(key)"] = value }
    }
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
    "style/label_font_point", "style/comment_font_point", "style/candidate_list_layout",
    "style/text_orientation", "style/corner_radius", "style/hilited_corner_radius",
    "style/border_height", "style/border_width", "style/line_spacing", "style/spacing",
    "style/alpha", "style/candidate_format", "style/inline_preedit", "style/inline_candidate",
    "style/translucency", "style/show_paging", "style/memorize_size", "style/mutual_exclusive",
    "keyboard_layout", "show_notifications_when"
  ]

  static let managedDefaultKeys: Set<String> = [
    "schema_list", "menu/page_size", "ascii_composer/good_old_caps_lock",
    "ascii_composer/switch_key/Caps_Lock", "ascii_composer/switch_key/Shift_L",
    "ascii_composer/switch_key/Shift_R", "ascii_composer/switch_key/Control_L",
    "ascii_composer/switch_key/Control_R", "switcher/hotkeys", "switcher/caption"
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
    set["style/color_scheme_dark"] = followSystemAppearance ? .string(colorSchemeDarkID) : PatchValue?.none
    set["style/font_face"] = fontFace.isEmpty ? PatchValue?.none : .string(fontFace)
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
    put(&set, "style/candidate_format", .string(candidateFormat), defaultValue: defaults["style/candidate_format"])
    put(&set, "style/inline_preedit", .bool(inlinePreedit), defaultValue: defaults["style/inline_preedit"])
    put(&set, "style/inline_candidate", .bool(inlineCandidate), defaultValue: defaults["style/inline_candidate"])
    put(&set, "style/translucency", .bool(translucency), defaultValue: defaults["style/translucency"])
    put(&set, "style/show_paging", .bool(showPaging), defaultValue: defaults["style/show_paging"])
    put(&set, "style/memorize_size", .bool(memorizeSize), defaultValue: defaults["style/memorize_size"])
    put(&set, "style/mutual_exclusive", .bool(mutualExclusive), defaultValue: defaults["style/mutual_exclusive"])
    set["keyboard_layout"] = keyboardLayout == "last" ? PatchValue?.none : .string(keyboardLayout)
    set["show_notifications_when"] = showNotificationsWhen == "appropriate" ? PatchValue?.none : .string(showNotificationsWhen)

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
    guard canWrite else {
      lastError = unparsableWarning
      return
    }
    isApplying = true
    lastError = nil
    statusMessage = "status.saving"
    do {
      let squirrelSet = compileSquirrelPatch()
      let defaultSet = compileDefaultPatch()
      for (key, value) in squirrelSet { squirrelPatch.set(value?.yamlObject, forPath: key) }
      for (key, value) in defaultSet { defaultPatch.set(value?.yamlObject, forPath: key) }
      try squirrelPatch.save()
      try defaultPatch.save()
      baselineSquirrel = squirrelSet
      baselineDefault = defaultSet

      if environment.isInstalled {
        statusMessage = "status.deploying"
        try SquirrelBridge.deploy(environment: environment)
        statusMessage = "status.deployed"
      } else {
        statusMessage = "status.savedWithoutSquirrel"
      }
    } catch {
      lastError = error.localizedDescription
      statusMessage = "status.writeFailed"
    }
    isApplying = false
  }

  func revert() {
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
    do {
      try squirrelPatch.save()
      try defaultPatch.save()
      reload()
      if environment.isInstalled { try SquirrelBridge.deploy(environment: environment) }
      statusMessage = "status.reset"
    } catch {
      lastError = error.localizedDescription
    }
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
    colorSchemes.first { $0.id == colorSchemeID } ?? .native
  }
}
