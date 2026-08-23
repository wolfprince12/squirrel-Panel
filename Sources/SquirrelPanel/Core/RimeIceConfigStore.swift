//
//  RimeIceConfigStore.swift
//  Squirrel Panel
//
//  雾凇拼音 (rime-ice) 专属配置的唯一数据源。
//
//  设计铁律（见实现计划第二节）：
//  1. 本类**独占** `rime_ice.custom.yaml`，绝不直接 save() `default.custom.yaml`。
//  2. 凡是必须落到 `default.custom.yaml` 的（`switcher/save_options`、双拼 `schema_list`），
//     一律改写 `SettingsStore` 的 @Published 属性，最后由 `settings.apply()` 统一落盘 + 部署。
//  3. `switches` 是列表不是映射，采用「读出厂模板 → 改托管项 reset → 整段写回」。
//  4. `reset`（固定默认）与 `save_options`（开关记忆）互斥：设固定默认时把该项从 save_options 摘除。
//  5. `engine/translators`、`engine/filters`、`schema/dependencies`、`speller/algebra` 是列表，
//     采用「列表托管合并」：只增删本类认得的条目，用户自己加的条目原样保留；
//     合并结果与出厂模板完全一致时写 nil（删键，回落出厂）。
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

/// 从 rime_ice.schema.yaml 解析出的出厂模板全集（reload 时读一次，缓存）
private struct RimeIceTemplate {
  var switches: [RimeIceSwitchTemplate] = []
  var translators: [String] = []
  var filters: [String] = []
  var dependencies: [String] = []
  var algebra: [String] = []
  var opencc: String = "s2t.json"
}

/// 界面上的一个 switch 行
struct RimeIceSwitchItem: Identifiable {
  var id: String { name }
  let name: String
  let states: [String]
  let abbrev: [String]?
  var mode: SwitchDefaultMode
}

/// 模糊音规则分组
enum FuzzyRuleGroup: String, CaseIterable, Identifiable {
  case initials
  case finals
  case syllables

  var id: String { rawValue }

  var titleKey: LocalizedStringKey {
    switch self {
    case .initials: return "riceice.fuzzy.initials"
    case .finals: return "riceice.fuzzy.finals"
    case .syllables: return "riceice.fuzzy.syllables"
    }
  }
}

/// 一条模糊音规则：`rule` 是写进 `speller/algebra` 的原文，`label` 是界面上的人类可读描述
struct FuzzyRule: Identifiable, Hashable {
  var id: String { rule }
  let rule: String
  let label: String
  let group: FuzzyRuleGroup
}

/// 拼音纠错强度
enum CorrectionStrength: Int, CaseIterable, Identifiable {
  case basic = 1      // 仅键盘物理相邻错打
  case standard = 2   // 相邻错打 + 系统性音近纠错
  var id: Int { rawValue }
  /// 稳定、非本地化的名称（预留给新引擎写入 ~/Library/Rime/correction_strength.txt）。
  var name: String {
    switch self {
    case .basic: return "basic"
    case .standard: return "standard"
    }
  }
  var label: String {
    switch self {
    case .basic: return String(localized: "correction.strength.basic")
    case .standard: return String(localized: "correction.strength.standard")
    }
  }
}

/// 纠错候选的注入位置（相对自然候选）。
enum CorrectionInjectionPosition: Int, CaseIterable, Identifiable {
  case top = 0        // 始终置顶（首位）
  case afterFirst = 1 // 第一条自然候选之后（默认）
  case end = 9        // 末尾
  var id: Int { rawValue }
  /// 稳定、非本地化的名称（预留给新引擎写入 ~/Library/Rime/correction_position.txt）。
  var name: String {
    switch self {
    case .top: return "top"
    case .afterFirst: return "afterFirst"
    case .end: return "end"
    }
  }
  var label: String {
    switch self {
    case .top: return String(localized: "correction.position.top")
    case .afterFirst: return String(localized: "correction.position.afterFirst")
    case .end: return String(localized: "correction.position.end")
    }
  }
}

@MainActor
@Observable
final class RimeIceConfigStore {

  /// SettingsStore 是 default.custom.yaml 的唯一通道；用 unowned 避免与 store.rimeIce 形成强引用环。
  unowned let settings: SettingsStore

  private var icePatch: CustomYAMLFile
  private var baselineIce: PatchSet = [:]

  /// 出厂模板（reload 时从 rime_ice.schema.yaml 读一次，缓存）
  private var template = RimeIceTemplate()

  /// 出厂 `default.yaml` 的 `switcher/save_options` 名单（reload 时读一次，缓存）。
  ///
  /// 判断「开关是否停在出厂默认」必须带上它：rime-ice 出厂把 6 个开关里的 5 个
  /// （ascii_punct / traditionalization / emoji / full_shape / search_single_char）
  /// 写进了 save_options，它们的出厂态是「记忆」而非任何一侧的固定默认。
  /// 只按 `reset` 判定会把这 5 项一律当成「被用户改过」，`switchesAreAllFactory`
  /// 恒 false → 干净安装也会往 rime_ice.custom.yaml 里整段写 switches（整段替换非追加），
  /// 上游日后调整 switches 会被这份陈旧快照永久覆盖。
  ///
  /// **只在 reload() 里读一次盘**：`compileIcePatch()` 挂在 SwiftUI 求值路径上，
  /// 每帧都会跑，绝不能在其中做磁盘 I/O。
  private var cachedFactorySaveOptions: Set<String> = []

  /// reload 期间抑制属性观察器的副作用（避免回写 SettingsStore 造成递归）
  private var isReloading = false

  // MARK: - UI 状态：基础开关（Phase B）

  var switches: [RimeIceSwitchItem] = []

  // 候选词数（menu/page_size）**不再由本面板管理**：
  // 唯一入口是「按键与行为」面板的全局 `menu/page_size`（SettingsStore.pageSize），
  // rime-ice 永远继承全局，绝不写方案级覆盖。见 `compileIcePatch()` 里的删键逻辑。

  // MARK: - UI 状态：词库与短语（Phase C）

  /// 英文输入 melt_eng（translator + dependency 成对，autocap / reduce_english 随之同生同死）
  var enableMeltEng: Bool = true
  /// 中英混合词 cn_en
  var enableCnEn: Bool = true
  /// 部件拆字（translator + 两个 filter + dependency 四者联动）
  var enableRadical: Bool = true
  /// Emoji 词库 simplifier@emoji
  var enableEmojiDict: Bool = true
  /// 自定义短语文件；目标随当前激活方案在
  /// custom_phrase.txt（全拼）与 custom_phrase_double.txt（双拼）之间切换
  var phrases: CustomPhraseFile

  // MARK: - UI 状态：语言与拼音（Phase D）

  /// 繁体类型：s2t.json | s2hk.json | s2tw.json | s2twp.json
  var opencc: String = "s2t.json"
  /// 当前排在 schema_list 首位的拼音类方案（rime_ice = 全拼）
  var activePinyinSchemaID: String = "rime_ice" {
    didSet {
      guard !isReloading, oldValue != activePinyinSchemaID else { return }
      promoteActivePinyinSchema()
      loadDoublePinyinPatch(for: activePinyinSchemaID)
      syncPhraseFile()
    }
  }
  /// 双拼「编码原样显示」：写 `<dp>.custom.yaml` 的 `translator/preedit_format: []`
  var showRawDoubleCode: Bool = false

  // MARK: - UI 状态：高级（Phase E）

  /// 6 个可独立开关的 Lua 滤镜，键为 lua 名（如 `*corrector`）
  var luaFilters: [String: Bool] = [:]
  /// 已选中的模糊音规则（值为 `speller/algebra` 中的规则原文）
  var fuzzySelection: Set<String> = []

  // MARK: - UI 状态：拼音纠错（占位接口，引擎待重做）

  /// 是否启用拼音实时纠错（按错键自动纠正）。占位属性：新引擎接入前不起作用。
  var correctionEnabled: Bool = false
  /// 纠错强度：基础 / 标准（占位）。
  var correctionStrength: CorrectionStrength = .standard
  /// 纠错候选注入位置：首位 / 首条之后 / 末尾（占位）。
  var correctionInjectionPosition: CorrectionInjectionPosition = .afterFirst
  /// 是否启用用户自学习（占位）。
  var correctionSelfLearning: Bool = true

  // MARK: - 双拼方案自己的补丁文件（非 default / 非 rime_ice）

  private var doublePinyinPatch: CustomYAMLFile?
  private var baselineShowRawDoubleCode = false

  // MARK: - 托管常量（照抄 rime_ice.schema.yaml，杜绝手写错）

  /// 本类托管的 rime_ice.custom.yaml 键（「恢复默认」只清理这些）。
  ///
  /// `menu/page_size` 仍在名单里，但语义已变成「只删不写」：候选数改由「按键与行为」
  /// 面板全局托管，这里保留它是为了清掉 v1.2.0 遗留的方案级覆盖（方案级会压过全局）。
  static let managedIceKeys: Set<String> = [
    "switches", "menu/page_size", "traditionalize/opencc_config",
    "engine/translators", "engine/filters", "schema/dependencies", "speller/algebra",
    "grammar",
    // 历史残留清理：旧版本曾挂载 AI processor 于 engine/processors/@after 0。切勿用
    // set(nil, forPath:) 清它（会序列化成 engine/processors: {} 清空内置处理器、导致
    // 候选框消失）；交由 removeManaged 直接删除该键即可。
    "engine/processors/@after 0"
  ]

  /// 托管的 translators 条目
  static let managedTranslators: Set<String> = [
    "table_translator@melt_eng",
    "table_translator@cn_en",
    "table_translator@radical_lookup"
  ]

  /// 托管的 filters 条目
  static let managedFilters: Set<String> = [
    "lua_filter@*corrector",
    "lua_filter@*autocap_filter",
    "lua_filter@*v_filter",
    "lua_filter@*pin_cand_filter",
    "lua_filter@*long_word_filter",
    "lua_filter@*reduce_english_filter",
    "simplifier@emoji",
    "lua_filter@*search@radical_pinyin",
    "reverse_lookup_filter@radical_reverse_lookup"
  ]

  /// 托管的 dependencies 条目
  static let managedDependencies: Set<String> = ["melt_eng", "radical_pinyin"]

  /// 未安装雾凇拼音时用于**占位展示**的开关行（置灰不可改，永不落盘）。
  ///
  /// 出厂 rime-ice 把 6 个开关里的 5 个写进了 `switcher/save_options`（即「记忆」），
  /// 只有 `ascii_mode` 是固定关——这里照抄该事实，用户装好之后界面不会突然跳变。
  /// `states` 有意留空：真实文案要从 rime_ice.schema.yaml 读，装之前不该编造，
  /// 留空时 `RimeIcePage.switchRow` 会自动省掉那行状态副标题。
  static let previewSwitches: [RimeIceSwitchItem] = [
    RimeIceSwitchItem(name: "ascii_mode", states: [], abbrev: nil, mode: .off),
    RimeIceSwitchItem(name: "ascii_punct", states: [], abbrev: nil, mode: .remember),
    RimeIceSwitchItem(name: "traditionalization", states: [], abbrev: nil, mode: .remember),
    RimeIceSwitchItem(name: "emoji", states: [], abbrev: nil, mode: .remember),
    RimeIceSwitchItem(name: "full_shape", states: [], abbrev: nil, mode: .remember),
    RimeIceSwitchItem(name: "search_single_char", states: [], abbrev: nil, mode: .remember)
  ]

  /// 可独立开关的 6 个 Lua 滤镜（键 = lua 名，实际条目为 `lua_filter@` + 键）
  static let luaFilterKeys: [String] = [
    "*corrector", "*autocap_filter", "*v_filter",
    "*pin_cand_filter", "*long_word_filter", "*reduce_english_filter"
  ]

  /// 英文开关关闭时必须一并摘除的 Lua 滤镜
  static let englishBoundLuaFilters: Set<String> = ["*autocap_filter", "*reduce_english_filter"]

  /// 繁体类型可选值（Rime 内置 OpenCC 配置）
  static let openccOptions: [String] = ["s2t.json", "s2hk.json", "s2tw.json", "s2twp.json"]

  /// 出厂模板中默认注释掉的模糊音规则表（原文取自 rime_ice.schema.yaml）
  static let fuzzyRules: [FuzzyRule] = [
    // 声母
    FuzzyRule(rule: "derive/^([zcs])h/$1/", label: "zh, ch, sh → z, c, s", group: .initials),
    FuzzyRule(rule: "derive/^([zcs])([^h])/$1h$2/", label: "z, c, s → zh, ch, sh", group: .initials),
    FuzzyRule(rule: "derive/^l/n/", label: "l → n", group: .initials),
    FuzzyRule(rule: "derive/^n/l/", label: "n → l", group: .initials),
    FuzzyRule(rule: "derive/^f/h/", label: "f → h", group: .initials),
    FuzzyRule(rule: "derive/^h/f/", label: "h → f", group: .initials),
    FuzzyRule(rule: "derive/^l/r/", label: "l → r", group: .initials),
    FuzzyRule(rule: "derive/^r/l/", label: "r → l", group: .initials),
    FuzzyRule(rule: "derive/^g/k/", label: "g → k", group: .initials),
    FuzzyRule(rule: "derive/^k/g/", label: "k → g", group: .initials),
    // 韵母
    FuzzyRule(rule: "derive/ang$/an/", label: "ang → an", group: .finals),
    FuzzyRule(rule: "derive/an$/ang/", label: "an → ang", group: .finals),
    FuzzyRule(rule: "derive/eng$/en/", label: "eng → en", group: .finals),
    FuzzyRule(rule: "derive/en$/eng/", label: "en → eng", group: .finals),
    FuzzyRule(rule: "derive/in$/ing/", label: "in → ing", group: .finals),
    FuzzyRule(rule: "derive/ing$/in/", label: "ing → in", group: .finals),
    FuzzyRule(rule: "derive/ian$/iang/", label: "ian → iang", group: .finals),
    FuzzyRule(rule: "derive/iang$/ian/", label: "iang → ian", group: .finals),
    FuzzyRule(rule: "derive/uan$/uang/", label: "uan → uang", group: .finals),
    FuzzyRule(rule: "derive/uang$/uan/", label: "uang → uan", group: .finals),
    FuzzyRule(rule: "derive/ai$/an/", label: "ai → an", group: .finals),
    FuzzyRule(rule: "derive/an$/ai/", label: "an → ai", group: .finals),
    FuzzyRule(rule: "derive/ong$/un/", label: "ong → un", group: .finals),
    FuzzyRule(rule: "derive/un$/ong/", label: "un → ong", group: .finals),
    FuzzyRule(rule: "derive/ong$/on/", label: "ong → on", group: .finals),
    FuzzyRule(rule: "derive/iong$/un/", label: "iong → un", group: .finals),
    FuzzyRule(rule: "derive/un$/iong/", label: "un → iong", group: .finals),
    FuzzyRule(rule: "derive/ong$/eng/", label: "ong → eng", group: .finals),
    FuzzyRule(rule: "derive/eng$/ong/", label: "eng → ong", group: .finals),
    // 音节
    FuzzyRule(rule: "derive/^fei$/hui/", label: "fei → hui", group: .syllables),
    FuzzyRule(rule: "derive/^hui$/fei/", label: "hui → fei", group: .syllables),
    FuzzyRule(rule: "derive/^hu$/fu/", label: "hu → fu", group: .syllables),
    FuzzyRule(rule: "derive/^fu$/hu/", label: "fu → hu", group: .syllables),
    FuzzyRule(rule: "derive/^wang$/huang/", label: "wang → huang", group: .syllables),
    FuzzyRule(rule: "derive/^huang$/wang/", label: "huang → wang", group: .syllables)
  ]

  /// 模糊音规则原文集合，用于从用户现有 algebra 中识别并剥离
  static let fuzzyRuleSet: Set<String> = Set(fuzzyRules.map(\.rule))

  /// 拼音类方案（全拼 rime_ice + 各家双拼）
  static func isPinyinFamily(_ id: String) -> Bool {
    id == "rime_ice" || id.hasPrefix("double_pinyin")
  }

  // MARK: - 自定义短语文件的归属

  /// 全拼的自定义短语文件（rime_ice.schema.yaml 的 `custom_phrase/user_dict: custom_phrase`）
  static let phraseFileFullPinyin = "custom_phrase.txt"
  /// 双拼的自定义短语文件：所有 `double_pinyin*.schema.yaml` 的
  /// `custom_phrase/user_dict` 都是 `custom_phrase_double`，与全拼是两个独立词典。
  static let phraseFileDoublePinyin = "custom_phrase_double.txt"

  /// 某个拼音方案对应的短语文件名。非 rime_ice（即各家双拼）一律用双拼词典。
  static func phraseFileName(forSchema id: String) -> String {
    (id.isEmpty || id == "rime_ice") ? phraseFileFullPinyin : phraseFileDoublePinyin
  }

  /// 当前激活方案对应的短语文件位置
  private var phraseFileURL: URL {
    RimeEnvironment.userDirectory
      .appending(path: Self.phraseFileName(forSchema: activePinyinSchemaID))
  }

  /// 切换拼音方案时短语文件保存失败后的上层提示（UI 展示用）。
  /// 仅当 `syncPhraseFile()` 保存旧文件失败（只读目录 / 磁盘满 / 权限）时才有值，
  /// 此时会**阻止**指针重指向，未保存词条留在编辑器里，绝不静默丢失。
  var phraseSaveError: String?

  /// 切换拼音方案后把短语编辑器指向新方案的词典文件。
  /// 切换前若旧文件有未保存内容，先落盘到**旧文件**——用户手打的词条不能因为
  /// 动了一下方案选择器就凭空消失，也绝不能被写进另一个方案的词典。
  ///
  /// 保存一旦失败（目录只读、磁盘满、权限不足等），**必须阻止**重指向：否则下一行
  /// 会把 `phrases` 重指向新文件，未保存词条随之蒸发且零提示。此时保留旧 `phrases`
  /// 并把错误暴露给 UI，让用户看到并主动处理，而不是吞掉。
  private func syncPhraseFile() {
    let url = phraseFileURL
    // 清错误必须在 early-return 之前：失败后用户把方案 Picker 切回原方案时，
    // 目标文件与当前指针一致会命中下面的 guard 直接返回，红条否则永远消不掉。
    phraseSaveError = nil
    guard phrases.fileURL != url else { return }
    guard phrases.isDirty else {
      phrases = CustomPhraseFile(fileURL: url)
      return
    }
    do {
      try phrases.save()
      phrases = CustomPhraseFile(fileURL: url)
    } catch {
      phraseSaveError = error.localizedDescription
    }
  }

  // MARK: - 生命周期

  init(settings: SettingsStore) {
    self.settings = settings
    self.icePatch = CustomYAMLFile(fileURL: RimeEnvironment.userDirectory.appending(path: "rime_ice.custom.yaml"))
    // 占位：真正的归属在 reload() 里按当前激活方案决定
    self.phrases = CustomPhraseFile(
      fileURL: RimeEnvironment.userDirectory.appending(path: Self.phraseFileFullPinyin))
    reload()
  }

  /// 雾凇拼音方案（rime_ice.schema.yaml）已安装才启用配置区，否则整段置灰
  var isInstalled: Bool { !template.switches.isEmpty }

  var canWrite: Bool { icePatch.isWritable }

  var unparsableWarning: String? {
    if case .unparsable(let reason) = icePatch.state {
      return String(format: String(localized: "error.parse.riceice"), reason)
    }
    return nil
  }

  /// rime_ice.custom.yaml 的磁盘位置（原始 YAML 编辑器要用）
  var iceFileURL: URL { icePatch.fileURL }

  func reload() {
    isReloading = true
    defer { isReloading = false }

    // 陈旧的短语保存错误横幅不能穿越 reload 存活。
    // 下面给 activePinyinSchemaID 赋值时 isReloading 已为 true，didSet 被抑制，
    // syncPhraseFile() 不会执行，红条没有别的清除时机——用户保存失败后点「还原」
    // （revert → settings.reload → 本方法）也消不掉，只能重启 App。
    phraseSaveError = nil

    template = Self.parseTemplate(environment: settings.environment)
    // 出厂 save_options 名单：整个生命周期只在这里读盘一次，
    // 供 switchesAreAllFactory / resetManagedRimeIce 判定「出厂开关模式」。
    cachedFactorySaveOptions = Set(factorySaveOptions())
    icePatch.load()

    // 拼音方案：从 default.custom.yaml（经 SettingsStore）已启用列表推断，首位的拼音类方案即当前方案
    activePinyinSchemaID = settings.enabledSchemaIDs.first(where: { Self.isPinyinFamily($0) }) ?? "rime_ice"
    loadDoublePinyinPatch(for: activePinyinSchemaID)
    // 短语文件归属取决于上面刚定下来的方案，必须在其之后重建
    phrases = CustomPhraseFile(fileURL: phraseFileURL)

    guard isInstalled else {
      // 未安装时没有出厂模板可读，但界面仍要把 6 个开关行**展示出来**（置灰不可改），
      // 让用户先看清面板提供哪些能力。这批占位项**永远不会落盘**：
      // switches 只被 compileIcePatch() 与 contribute(to:) 消费，二者均以 `guard isInstalled`
      // 开头直接短路；writePatch() / resetManagedRimeIce() 同样以该 guard 保驾（writePatch 在
      // guard 前还有 phrases.save / writeDoublePinyinPatch 两条前置写盘路径，但二者都不触碰
      // switches），因此未安装时占位项没有任何一条路径能写进磁盘。
      switches = Self.previewSwitches
      opencc = "s2t.json"
      enableMeltEng = true
      enableCnEn = true
      enableRadical = true
      enableEmojiDict = true
      luaFilters = Dictionary(uniqueKeysWithValues: Self.luaFilterKeys.map { ($0, true) })
      fuzzySelection = []
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

    switches = template.switches.map { t in
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

    opencc = icePatch.string(forPath: "traditionalize/opencc_config") ?? template.opencc

    // 列表型托管项：以「用户现状」为准，缺省回落出厂模板
    let currentTranslators = currentList("engine/translators", fallback: template.translators)
    let currentFilters = currentList("engine/filters", fallback: template.filters)
    let currentAlgebra = currentList("speller/algebra", fallback: template.algebra)

    enableMeltEng = currentTranslators.contains("table_translator@melt_eng")
    enableCnEn = currentTranslators.contains("table_translator@cn_en")
    enableRadical = currentTranslators.contains("table_translator@radical_lookup")
    enableEmojiDict = currentFilters.contains("simplifier@emoji")

    var lua: [String: Bool] = [:]
    for key in Self.luaFilterKeys {
      if !enableMeltEng && Self.englishBoundLuaFilters.contains(key) {
        // 英文关闭时这两项被强制摘除，界面记忆为「开」，重新开启英文后随之恢复
        lua[key] = true
      } else {
        lua[key] = currentFilters.contains("lua_filter@" + key)
      }
    }
    luaFilters = lua

    fuzzySelection = Set(currentAlgebra.filter { Self.fuzzyRuleSet.contains($0) })

    baselineIce = compileIcePatch()
  }

  // MARK: - 读出厂模板

  /// 从 rime_ice.schema.yaml 解析出厂模板。
  ///
  /// **只认非 build/ 的源文件**，取不到就返回空模板（面板随之整段置灰）。
  /// 绝不回退去读 `build/` 里的编译产物——那份已经合并过我们自己打的补丁，
  /// 拿它当「出厂模板」会形成反馈环：用户勾选的模糊音会被认成出厂自带，
  /// 下次编译时因「与出厂一致」而写 nil，规则就此静默消失。
  private static func parseTemplate(environment: RimeEnvironment) -> RimeIceTemplate {
    var result = RimeIceTemplate()
    let urls = environment.configSources(named: "rime_ice.schema.yaml")
    guard let url = urls.first(where: { !$0.pathComponents.contains("build") }),
          let text = try? String(contentsOf: url, encoding: .utf8),
          let object = try? Yams.load(yaml: text) as? [String: Any] else { return result }

    if let list = object["switches"] as? [[String: Any]] {
      result.switches = list.compactMap { item -> RimeIceSwitchTemplate? in
        guard let name = item["name"] as? String else { return nil }
        let states = (item["states"] as? [Any])?.compactMap { "\($0)" } ?? []
        let abbrev = (item["abbrev"] as? [Any])?.compactMap { "\($0)" }
        let reset = (item["reset"] as? Int) ?? 0
        return RimeIceSwitchTemplate(name: name, states: states, abbrev: abbrev, factoryReset: reset)
      }
    }
    if let engine = object["engine"] as? [String: Any] {
      result.translators = stringList(engine["translators"])
      result.filters = stringList(engine["filters"])
    }
    if let schema = object["schema"] as? [String: Any] {
      result.dependencies = stringList(schema["dependencies"])
    }
    if let speller = object["speller"] as? [String: Any] {
      result.algebra = stringList(speller["algebra"])
    }
    if let traditionalize = object["traditionalize"] as? [String: Any],
       let config = traditionalize["opencc_config"] as? String {
      result.opencc = config
    }
    return result
  }

  private static func stringList(_ node: Any?) -> [String] {
    guard let list = node as? [Any] else { return [] }
    return list.compactMap { $0 as? String }
  }

  /// 读取当前补丁中的列表。
  ///
  /// 区分「键不存在」与「显式空列表」：
  /// 键不存在才回落出厂模板；用户手写 `engine/filters: []` 是明确表态
  /// （「这条链上只留我允许的东西」），必须尊重，不能把整套出厂条目塞回去。
  private func currentList(_ path: String, fallback: [String]) -> [String] {
    guard let list = icePatch.value(forPath: path) as? [Any] else { return fallback }
    return list.compactMap { $0 as? String }
  }

  // MARK: - 列表型托管合并

  /// 列表托管合并算法（借鉴 SettingsStore.mergedTabBindingAppendList 的三要素，另加顺序锚点）：
  /// ① 以 current（用户现状）为骨架：剔除被关闭的托管项、去重，其余原样保留；
  /// ② 缺失的已开启托管项，按 template 中的相对位置（前邻优先、后邻兜底）插回。
  ///
  /// 顺序锚点由 template 自身保证（rime-ice 注释要求：pin_cand > emoji > traditionalize、long_word > emoji）。
  static func mergedList(template: [String],
                         current: [String],
                         managed: Set<String>,
                         isEnabled: (String) -> Bool) -> [String] {
    var result: [String] = []
    var seen = Set<String>()

    for item in current {
      if managed.contains(item) && !isEnabled(item) { continue }
      if seen.contains(item) { continue }
      seen.insert(item)
      result.append(item)
    }

    for (index, item) in template.enumerated() {
      guard managed.contains(item), isEnabled(item), !seen.contains(item) else { continue }
      var insertAt = result.count
      if let anchor = template[0..<index].reversed().first(where: { result.contains($0) }),
         let position = result.firstIndex(of: anchor) {
        insertAt = position + 1
      } else if let anchor = template[(index + 1)...].first(where: { result.contains($0) }),
                let position = result.firstIndex(of: anchor) {
        insertAt = position
      }
      result.insert(item, at: insertAt)
      seen.insert(item)
    }
    return result
  }

  /// 成对约束集中在这里：melt_eng 的 translator 与 dependency 同生同死；
  /// 部件拆字牵动 translator + 两个 filter + dependency；英文关闭时 autocap / reduce_english 必随关。
  private func isTranslatorEnabled(_ item: String) -> Bool {
    switch item {
    case "table_translator@melt_eng": return enableMeltEng
    case "table_translator@cn_en": return enableCnEn
    case "table_translator@radical_lookup": return enableRadical
    default: return true
    }
  }

  private func isFilterEnabled(_ item: String) -> Bool {
    switch item {
    case "simplifier@emoji":
      return enableEmojiDict
    case "lua_filter@*search@radical_pinyin", "reverse_lookup_filter@radical_reverse_lookup":
      return enableRadical
    default:
      guard item.hasPrefix("lua_filter@") else { return true }
      let key = String(item.dropFirst("lua_filter@".count))
      guard Self.luaFilterKeys.contains(key) else { return true }
      if Self.englishBoundLuaFilters.contains(key) && !enableMeltEng { return false }
      return luaFilters[key] ?? true
    }
  }

  private func isDependencyEnabled(_ item: String) -> Bool {
    switch item {
    case "melt_eng": return enableMeltEng
    case "radical_pinyin": return enableRadical
    default: return true
    }
  }

  private func mergedTranslators() -> [String] {
    Self.mergedList(template: template.translators,
                    current: currentList("engine/translators", fallback: template.translators),
                    managed: Self.managedTranslators,
                    isEnabled: { self.isTranslatorEnabled($0) })
  }

  private func mergedFilters() -> [String] {
    let result = Self.mergedList(template: template.filters,
                    current: currentList("engine/filters", fallback: template.filters),
                    managed: Self.managedFilters,
                    isEnabled: { self.isFilterEnabled($0) })
    return result
  }

  private func mergedDependencies() -> [String] {
    Self.mergedList(template: template.dependencies,
                    current: currentList("schema/dependencies", fallback: template.dependencies),
                    managed: Self.managedDependencies,
                    isEnabled: { self.isDependencyEnabled($0) })
  }

  /// 模糊音：把已选规则**前置**到用户现有 algebra 之前；
  /// 出厂常驻规则（erase / abbrev / v-u 转换 / 自动纠错）原样保留。
  private func mergedAlgebra() -> [String] {
    let current = currentList("speller/algebra", fallback: template.algebra)
    let base = current.filter { !Self.fuzzyRuleSet.contains($0) }
    let fuzzySel = Self.fuzzyRules.map(\.rule).filter { fuzzySelection.contains($0) }
    return fuzzySel + base
  }

  // MARK: - 写：界面 → 补丁

  /// 界面上的开关是否全部停在出厂默认。
  ///
  /// 出厂默认分两种，缺一不可：
  /// - 名字在出厂 `default.yaml` 的 `switcher/save_options` 里 → 出厂态是「记忆」；
  /// - 否则看方案里写的 `reset`（没写即 0 → 固定关）。
  ///
  /// 漏掉前者会让 5/6 个开关在干净安装下就被判成「已改动」，switches 整段被无谓写入
  /// rime_ice.custom.yaml，等于给上游的 switches 定义拍了张永久快照。
  private var switchesAreAllFactory: Bool {
    switches.allSatisfy { item in
      guard let t = template.switches.first(where: { $0.name == item.name }) else { return false }
      return item.mode == factoryMode(for: t)
    }
  }

  /// 某个出厂开关的出厂模式（save_options 优先于 reset）
  private func factoryMode(for t: RimeIceSwitchTemplate) -> SwitchDefaultMode {
    cachedFactorySaveOptions.contains(t.name) ? .remember : ((t.factoryReset == 1) ? .on : .off)
  }

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
    // 全部开关都停在出厂默认（没有 .remember，也没有任何固定默认覆盖）时写 nil，
    // 让 rime_ice.custom.yaml 里根本不出现 switches 段——「恢复默认」后文件才是干净的。
    set["switches"] = switchesAreAllFactory ? PatchValue?.none : .mapList(list)

    // 候选词数：**恒写 nil = 恒删键**。候选数的唯一入口是「按键与行为」面板的全局
    // menu/page_size，rime-ice 永远继承它，本面板不再提供方案级覆盖。
    //
    // 这里保留键、只写 nil（而不是整条去掉）是自愈路径：v1.2.0 曾允许用户在本面板
    // 拨候选数，那批用户的 rime_ice.custom.yaml 里躺着一个方案级 menu/page_size，
    // 方案级压过全局 —— 不显式删键的话，他们去「按键与行为」怎么改都没效果。
    set["menu/page_size"] = PatchValue?.none

    // 繁体类型：与出厂（s2t.json）相同则回落
    set["traditionalize/opencc_config"] = (opencc == template.opencc) ? PatchValue?.none : .string(opencc)

    // 三个列表型托管项 + 模糊音：合并结果等于出厂模板时写 nil，用户条目不丢
    // —— 列表型托管键：经「安全护栏」写入，绝不整体覆盖清空内置列表 ——
    // 见下方 safeListPatch：merged 为空 / 出厂模板不可信（base 解析失败）时一律回落，
    // 绝不写出 `key: []` 这类清空式补丁（那会废掉输入法）。
    let translators = mergedTranslators()
    set["engine/translators"] = Self.safeListPatch(merged: translators, template: template.translators)

    let filters = mergedFilters()
    set["engine/filters"] = Self.safeListPatch(merged: filters, template: template.filters)

    // ⚠️ 严禁在此写入 engine/processors（含写 nil / @after 0 = none）。Rime 的
    // engine/processors 由内置默认提供；一旦补丁里出现 engine/processors: {}（哪怕是
    // 清 key 产生的空映射），合并时会把内置默认处理器整体清空，导致按键完全不被处理、
    // 候选框彻底消失、中文输入报废。AI 处理器早已物理删除，此处不再需要任何清理，
    // 因此刻意不碰 engine/processors，让它回退到 Rime 内置默认。

    let dependencies = mergedDependencies()
    set["schema/dependencies"] = Self.safeListPatch(merged: dependencies, template: template.dependencies)

    // speller/algebra 是最致命的键：一旦整体覆盖写成残缺列表（仅面板自有规则），
    // 官方 47+ 条拼写规则全部丢失 → 拼音拼不出词、中文输入崩溃。
    //
    // ⚠️ 落盘判据必须用「当前磁盘实际」(current) 而非「出厂模板」(template)：
    // 拼音纠错 derive 规则是面板**非出厂**的增量——关闭纠错时 merged 退回工厂列表，
    // 若与 template 比较会判成「相等」而跳过写入，导致旧 derive 规则残留在 yaml 里、
    // 开关关不掉、UI 状态与磁盘脱钩。改为与 current 比较：有差异才整体写回（合并结果
    // 始终含真实工厂规则 + 面板增量，绝非残缺列表），无差异才回落，绝不写 : []。
    // 出厂模板不可信（base 解析失败、template 变空）时，merged 仍由 current 派生、
    // 必含真实工厂规则，整体写回安全；仅当 merged 本身为空才回落（避免清空输入法）。
    let currentAlgebra = currentList("speller/algebra", fallback: template.algebra)
    let algebra = mergedAlgebra()
    if algebra == currentAlgebra {
      set["speller/algebra"] = PatchValue?.none
    } else if algebra.isEmpty {
      set["speller/algebra"] = PatchValue?.none
    } else {
      set["speller/algebra"] = .stringList(algebra)
    }

    return set
  }

  /// 列表型键的安全写入护栏（根治「面板部署清空输入法」）。
  ///
  /// 面板对 `engine/translators` / `engine/filters` / `schema/dependencies` /
  /// `speller/algebra` 四类列表采用「整体覆盖」式补丁。若直接写 `key: []` 或仅含
  /// 面板自有条目的残缺列表，会清空 Rime 内置/出厂列表，导致候选框消失、中文报废。
  /// 本护栏从三个维度兜底：
  ///   1. `merged` 为空 → 写 nil（绝不 `: []` 清空）；
  ///   2. `critical` 键且出厂模板 `template` 为空（base schema 解析失败，不可信）→ 写 nil，
  ///      此时 merged 只是面板自有条目，整体覆盖会丢掉 base 里我们不知道的官方规则，
  ///      宁可功能不生效也绝不破坏输入法；
  ///   3. `merged` 与 `template` 一致 → 写 nil（与出厂相同不落盘，避免快照压制上游）；
  ///   4. 否则写完整 `merged`（= 实际安装全部官方规则 + 面板增量）。
  private static func safeListPatch(merged: [String], template: [String], critical: Bool = false) -> PatchValue? {
    // ① 空结果：写出 : [] 等于清空整个列表，直接废掉输入法，严禁。
    if merged.isEmpty { return PatchValue?.none }
    // ② critical 键 + 出厂模板不可信：任何整体覆盖都可能丢失官方未知规则，保守回落出厂。
    if critical && template.isEmpty { return PatchValue?.none }
    // ③ 与出厂一致：不落盘（保持补丁精简，且避免快照压制上游日后调整）。
    if merged == template { return PatchValue?.none }
    // ④ 仅当确有差异时，写回「完整 merged」——它包含实际安装的全部官方规则 + 面板增量。
    return .stringList(merged)
  }

  /// 由 SettingsStore.apply() 在统一落盘前调用：把「记忆」开关名同步进 save_options。
  ///
  /// `switcher/save_options` 是**全局**名单，五笔、仓颉等其他方案的开关也在里面。
  /// 只能增删雾凇自己那 6 个名字，整体覆盖会把别的方案的记忆项静默删掉。
  func contribute(to settings: SettingsStore) {
    guard isInstalled else { return }
    let remember = switches.filter { $0.mode == .remember }.map { $0.name }
    let mine = Set(template.switches.map { $0.name })
    let others = settings.savedSwitchOptions.filter { !mine.contains($0) }
    settings.savedSwitchOptions = others + remember
  }

  /// 把本面板编译结果写盘（自带 .bak + unparsable 拒写），并更新基线。
  /// 同时负责自定义短语与双拼方案补丁——它们都不属于 default.custom.yaml，可安全独立写入。
  func writePatch() throws {
    if phrases.isDirty { try phrases.save() }
    try writeDoublePinyinPatch()
    guard isInstalled, icePatch.isWritable else { return }
    let set = compileIcePatch()
    // 干净安装 + 全部托管项都回落出厂 = 一个键都不用写。此时凭空创建一份只有注释头、
    // 没有任何 patch 段的 rime_ice.custom.yaml 纯属垃圾文件：用户从没打开过雾凇面板，
    // 只在别处点了一次「应用」，家目录里就多出一个文件。
    //
    // 文件**已存在**时必须照常 save——那是删除历史托管键的自愈路径（旧版本写进去的
    // switches / save_options 快照要靠这一步清掉），跳过就永远自愈不了。
    let hasValueToWrite = set.values.contains { $0 != nil }
    let fileExists = FileManager.default.fileExists(
      atPath: icePatch.fileURL.path(percentEncoded: false))
    guard hasValueToWrite || fileExists else {
      baselineIce = set
      return
    }
    for (key, value) in set { icePatch.set(value?.yamlObject, forPath: key) }
    try icePatch.save()
    baselineIce = set
  }

  /// 雾凇面板自身的脏值判断（覆盖 B/C/D/E 全部状态）
  var isDirty: Bool {
    if phrases.isDirty { return true }
    if showRawDoubleCode != baselineShowRawDoubleCode { return true }
    guard isInstalled else { return false }
    return compileIcePatch() != baselineIce
  }

  // MARK: - 双拼方案

  /// 本机可选的拼音类方案（全拼 rime_ice + 已安装的各家双拼）
  var pinyinSchemaChoices: [RimeSchema] {
    var list = settings.availableSchemas.filter { Self.isPinyinFamily($0.id) }
    if !activePinyinSchemaID.isEmpty && !list.contains(where: { $0.id == activePinyinSchemaID }) {
      // 当前方案未被扫描到（例如刚被卸载），补一个占位项，保证 Picker 选中态不丢
      list.append(RimeSchema(id: activePinyinSchemaID, name: activePinyinSchemaID,
                             version: nil, author: nil, description: nil, isUserProvided: false))
    }
    return list
  }

  /// 当前是否为双拼方案（全拼 rime_ice 时「编码原样显示」不适用）
  var isDoublePinyinActive: Bool {
    !activePinyinSchemaID.isEmpty && activePinyinSchemaID != "rime_ice"
  }

  /// 把选中的拼音方案置于 schema_list 首位。
  /// 绝不直接写 default.custom.yaml——只改 SettingsStore 的 @Published，由 settings.apply() 统一落盘。
  private func promoteActivePinyinSchema() {
    guard !activePinyinSchemaID.isEmpty else { return }
    var ids = settings.enabledSchemaIDs
    ids.removeAll { $0 == activePinyinSchemaID }
    ids.insert(activePinyinSchemaID, at: 0)
    settings.enabledSchemaIDs = ids
  }

  /// 载入某个双拼方案自己的 `<id>.custom.yaml`，读出 `translator/preedit_format` 现状
  private func loadDoublePinyinPatch(for id: String) {
    guard !id.isEmpty, id != "rime_ice" else {
      doublePinyinPatch = nil
      showRawDoubleCode = false
      baselineShowRawDoubleCode = false
      return
    }
    let file = CustomYAMLFile(fileURL: RimeEnvironment.userDirectory.appending(path: "\(id).custom.yaml"))
    doublePinyinPatch = file
    // 空列表（[]）表示「不做任何 preedit 转换」，即原样显示双拼编码
    let raw = (file.value(forPath: "translator/preedit_format") as? [Any])?.isEmpty ?? false
    showRawDoubleCode = raw
    baselineShowRawDoubleCode = raw
  }

  /// 写双拼方案补丁（写前 .bak 由 CustomYAMLFile.save() 负责）
  private func writeDoublePinyinPatch() throws {
    guard let file = doublePinyinPatch, file.isWritable else { return }
    guard showRawDoubleCode != baselineShowRawDoubleCode else { return }
    file.set(showRawDoubleCode ? [String]() : nil, forPath: "translator/preedit_format")
    try file.save()
    baselineShowRawDoubleCode = showRawDoubleCode
  }

  // MARK: - 原始 YAML 编辑

  /// rime_ice.custom.yaml 的磁盘原文（文件不存在时给出即将写入的骨架）
  func rawIceText() -> String {
    if let text = try? String(contentsOf: icePatch.fileURL, encoding: .utf8) { return text }
    return (try? icePatch.serialize()) ?? ""
  }

  /// 校验原始 YAML；返回 nil 表示合法，否则返回错误描述
  func validateRawIce(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    do {
      guard let object = try Yams.load(yaml: text) else { return nil }
      guard object is [String: Any] else { return String(localized: "error.yaml.notMapping") }
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  /// 保存原始 YAML：校验 → .bak → 落盘 → 重载界面 → 部署
  func saveRawIce(_ text: String) throws {
    guard validateRawIce(text) == nil else {
      throw PanelError.refusedToOverwrite(icePatch.fileURL.lastPathComponent)
    }
    let url = icePatch.fileURL
    let fm = FileManager.default
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if fm.fileExists(atPath: url.path(percentEncoded: false)) {
      let backup = url.appendingPathExtension("bak")
      try? fm.removeItem(at: backup)
      try? fm.copyItem(at: url, to: backup)
    }
    var body = text
    if !body.hasSuffix("\n") { body += "\n" }
    try body.write(to: url, atomically: true, encoding: .utf8)
    reload()
    if settings.environment.isInstalled {
      try SquirrelBridge.deploy(environment: settings.environment)
    }
  }

  // MARK: - 恢复默认

  /// 把本面板管理的配置全部回到出厂默认：UI 状态回出厂、save_options 回落出厂。
  /// **不**直接落盘——改动进入 dirty 状态，用户需点底部「应用并重新部署」才会
  /// 一次落盘 + 部署（写盘逻辑集中在 apply → writePatch）。
  /// 与全项目「未应用即不落盘」铁律一致。
  ///
  /// 有意**不**重置 schema_list 中的拼音方案选择——那属于全局方案列表，
  /// 在「恢复雾凇默认」里悄悄改掉用户的双拼选择过于意外。
  func resetManagedRimeIce() {
    guard isInstalled else { return }
    // 1. UI 状态回出厂。开关模式同样要认出厂 save_options：
    //    出厂即「记忆」的 5 项若被一律设成固定开/关，磁盘结果虽然对
    //    （contribute 出空名单 → 删键回落 default 出厂值），界面却会错显成「固定关」
    //    直到下一次 reload，用户会以为重置把记忆功能关掉了。
    switches = template.switches.map { t in
      RimeIceSwitchItem(name: t.name, states: t.states, abbrev: t.abbrev, mode: factoryMode(for: t))
    }
    opencc = template.opencc
    // rime-ice 出厂全部词库 / 滤镜均为开启
    enableMeltEng = true
    enableCnEn = true
    enableRadical = true
    enableEmojiDict = true
    luaFilters = Dictionary(uniqueKeysWithValues: Self.luaFilterKeys.map { ($0, true) })
    fuzzySelection = []
    showRawDoubleCode = false
    // 2. 兜底清掉 rime_ice.custom.yaml 里的托管键。
    //    UI 已回出厂 → compileIcePatch() 会对全部托管项写 nil，本来就不会再写回去；
    //    这一步额外负责扫掉历史遗留（例如旧版本写过、现已不再编译的键），
    //    用户手写的其他条目不受影响。
    icePatch.removeManaged(keys: Self.managedIceKeys)
    // 注意：不再对 engine/processors 做任何 set(nil) / @after 0 清理。Rime 的
    // engine/processors 由内置默认提供，补丁里写 engine/processors: {}（哪怕是清 key
    // 产生的空映射）会清空内置默认处理器，导致候选框消失、中文报废。AI 处理器已物理
    // 删除，此处无需清理；保留内置默认即可。
    // 3. save_options 回落出厂
    settings.savedSwitchOptions = factorySaveOptions()
    // 4. 注意：此处**不**调 settings.apply()。
    //    UI 状态 / icePatch / savedSwitchOptions 与基线不再一致 → SettingsStore.isDirty
    //    变为 true，底部「应用并重新部署」按钮会被点亮，用户确认后再统一落盘 + 部署。
  }

  /// 急救机制：将雾凇拼音**所有**配置恢复到出厂默认状态。
  /// 与 `resetManagedRimeIce()` 的区别：会删除 `rime_ice.custom.yaml` 整个文件
  /// （包括用户手写的非托管键），并把 `default.custom.yaml` 的 save_options 回落出厂。
  /// `rime_ice.custom.yaml` 删除前自动备份为 `.bak`。
  ///
  /// 落盘 + 部署一气呵成（与 SettingsStore.resetSquirrelDefaults 同级「保险」语义，
  /// 用于「鼠标点错了什么配置把 rime-ice 搞乱了」的确诊与救场场景）。
  func resetAllRimeIceConfigs() {
    guard isInstalled else { return }
    let fm = FileManager.default
    let dir = RimeEnvironment.userDirectory

    // 1. 备份并删除 rime_ice.custom.yaml
    //    删除前复制一份 *.bak 落在同目录，用户可手动 mv 还原。
    let iceFile = dir.appendingPathComponent("rime_ice.custom.yaml")
    if fm.fileExists(atPath: iceFile.path) {
      let backup = iceFile.appendingPathExtension("bak")
      try? fm.removeItem(at: backup)
      try? fm.copyItem(at: iceFile, to: backup)
      try? fm.removeItem(at: iceFile)
    }

    // 2. save_options 回落出厂
    //    reload() 内部会读 settings.savedSwitchOptions 决定 switches 模式，
    //    所以必须在 reload() 之前赋值，否则会被磁盘上的旧值覆盖。
    settings.savedSwitchOptions = factorySaveOptions()

    // 3. 重新加载（读盘，icePatch 现在是空的，UI 状态回到出厂）
    reload()

    // 4. 落盘 + 部署（apply 会写 default.custom.yaml 的 save_options 并触发 deploy）
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
