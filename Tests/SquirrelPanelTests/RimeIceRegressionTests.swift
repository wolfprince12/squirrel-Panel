//
//  RimeIceRegressionTests.swift
//  Squirrel Panel
//
//  QA 补充的回归测试，覆盖 RimeIceMergeTests 未触及的三块：
//    ① 补丁值相等性（switches 整段含数组字段）——直接决定「是否有未保存改动」是否准确；
//    ② 托管常量表的自洽性——常量写错会让开关变成静默的空操作；
//    ③ 模糊音规则表的识别边界——不能把常驻规则或用户自写规则当成模糊音剥掉。
//

import XCTest
@testable import SquirrelPanel

@MainActor
final class RimeIceRegressionTests: XCTestCase {

  // MARK: - ① 补丁值相等性（决定 isDirty 是否准确）

  /// rime_ice.custom.yaml 的 `switches` 是「列表的映射」，每项都带 `states: [String]`。
  /// 两段内容完全相同的 switches 必须判定相等，否则 `compileIcePatch() != baselineIce`
  /// 恒成立，`RimeIceConfigStore.isDirty` / `SettingsStore.isDirty` 将永远为真。
  func testMapListEqualityHandlesArrayValues() {
    let a: [[String: Any]] = [
      ["name": "ascii_mode", "states": ["中", "Ａ"], "reset": 0],
      ["name": "search_single_char", "states": ["正常", "单字"], "abbrev": ["词", "单"]]
    ]
    let b: [[String: Any]] = [
      ["name": "ascii_mode", "states": ["中", "Ａ"], "reset": 0],
      ["name": "search_single_char", "states": ["正常", "单字"], "abbrev": ["词", "单"]]
    ]
    XCTAssertEqual(PatchValue.mapList(a), PatchValue.mapList(b),
                   "含数组字段的 mapList 必须可比较相等，否则 isDirty 恒为 true")
  }

  /// 内容不同的 switches 必须判定不等（避免为了修相等性而把比较写成恒真）
  func testMapListEqualityDetectsRealDifference() {
    let a: [[String: Any]] = [["name": "emoji", "states": ["💀", "😄"], "reset": 1]]
    let b: [[String: Any]] = [["name": "emoji", "states": ["💀", "😄"], "reset": 0]]
    XCTAssertNotEqual(PatchValue.mapList(a), PatchValue.mapList(b))

    let c: [[String: Any]] = [["name": "emoji", "states": ["💀", "😄"]]]
    XCTAssertNotEqual(PatchValue.mapList(a), PatchValue.mapList(c),
                      "从「固定开」切到「记忆」会删掉 reset 键，必须被识别为改动")
  }

  /// 整个 PatchSet 层面的稳定性：同样的编译结果两次比较必须相等
  func testPatchSetWithSwitchesIsStable() {
    let list: [[String: Any]] = [["name": "full_shape", "states": ["半角", "全角"], "reset": 0]]
    let first: PatchSet = ["switches": .mapList(list), "menu/page_size": .int(7)]
    let second: PatchSet = ["switches": .mapList(list), "menu/page_size": .int(7)]
    XCTAssertTrue(first == second, "编译结果与基线相同时必须判定为「无改动」")
  }

  // MARK: - ② 托管常量表自洽性

  /// 6 个 Lua 滤镜开关必须都在 managedFilters 白名单里，
  /// 否则 mergedList 不会把它当托管项处理，开关点了等于没点。
  func testLuaFilterKeysAreAllManaged() {
    for key in RimeIceConfigStore.luaFilterKeys {
      XCTAssertTrue(RimeIceConfigStore.managedFilters.contains("lua_filter@" + key),
                    "lua_filter@\(key) 不在 managedFilters 中，该开关将失效")
    }
  }

  /// 与英文输入同生同死的两个滤镜必须是可独立开关的那 6 个之一
  func testEnglishBoundFiltersAreKnownLuaFilters() {
    for key in RimeIceConfigStore.englishBoundLuaFilters {
      XCTAssertTrue(RimeIceConfigStore.luaFilterKeys.contains(key),
                    "\(key) 不在 luaFilterKeys 中，界面无法置灰")
    }
  }

  /// 三张托管表互不重叠，且都不为空
  func testManagedTablesAreDisjointAndNonEmpty() {
    XCTAssertFalse(RimeIceConfigStore.managedTranslators.isEmpty)
    XCTAssertFalse(RimeIceConfigStore.managedFilters.isEmpty)
    XCTAssertFalse(RimeIceConfigStore.managedDependencies.isEmpty)
    XCTAssertTrue(RimeIceConfigStore.managedTranslators
      .isDisjoint(with: RimeIceConfigStore.managedFilters))
    XCTAssertTrue(RimeIceConfigStore.managedTranslators
      .isDisjoint(with: RimeIceConfigStore.managedDependencies))
    XCTAssertTrue(RimeIceConfigStore.managedFilters
      .isDisjoint(with: RimeIceConfigStore.managedDependencies))
  }

  /// 「恢复默认」白名单必须覆盖 compileIcePatch() 实际写入的全部键，
  /// 否则重置会留下清不掉的残留。
  ///
  /// 注意：用「超集」而非「相等」。白名单还包含由语法模型包安装器写入的 `grammar`
  /// （octagram v1.3.0，重置时一并清掉），它不在 compileIcePatch() 的产出里。
  func testManagedIceKeysCoverEveryWrittenPath() {
    let written: Set<String> = [
      "switches", "menu/page_size", "traditionalize/opencc_config",
      "engine/translators", "engine/filters", "schema/dependencies", "speller/algebra"
    ]
    XCTAssertTrue(RimeIceConfigStore.managedIceKeys.isSuperset(of: written),
                  "managedIceKeys 未覆盖 compileIcePatch() 写入的键：\(written.subtracting(RimeIceConfigStore.managedIceKeys))")
  }

  // MARK: - ③ 模糊音规则表识别边界

  /// 规则原文不能重复（重复会让 Set 与数组长度不一致，界面出现两个同名开关）
  func testFuzzyRulesAreUnique() {
    XCTAssertEqual(RimeIceConfigStore.fuzzyRuleSet.count,
                   RimeIceConfigStore.fuzzyRules.count)
    XCTAssertEqual(Set(RimeIceConfigStore.fuzzyRules.map(\.label)).count,
                   RimeIceConfigStore.fuzzyRules.count)
  }

  /// 每组都要有内容，且规则一律是 derive（erase/abbrev 属于常驻规则，不能进模糊音表）
  func testFuzzyRulesAreAllDeriveAndGrouped() {
    for group in FuzzyRuleGroup.allCases {
      XCTAssertFalse(RimeIceConfigStore.fuzzyRules.filter { $0.group == group }.isEmpty,
                     "\(group.rawValue) 分组为空")
    }
    for rule in RimeIceConfigStore.fuzzyRules {
      XCTAssertTrue(rule.rule.hasPrefix("derive/"), "模糊音规则只能是 derive：\(rule.rule)")
    }
  }

  /// 剥离模糊音时，出厂常驻规则（超级简拼 erase/abbrev、v-u 转换、自动纠错）
  /// 与用户自写规则都必须原样留下——这是「合并写回不丢用户配置」的底线。
  func testStrippingFuzzyRulesKeepsAlwaysOnAndUserRules() {
    let alwaysOn = [
      "erase/^hm$/", "erase/^m$/", "erase/^n$/", "erase/^ng$/",
      "abbrev/^([a-z]).+$/$1/", "abbrev/^([zcs]h).+$/$1/",
      "derive/^([nl])ve$/$1ue/", "derive/^([jqxy])u/$1v/",
      "derive/^([nl])ue$/$1ve/", "derive/^([jqxy])v/$1u/",
      "derive/([zcs])h([aeiu])$/$1$2h/"
    ]
    let userOwn = ["derive/^wo$/vo/", "xform/^abc$/xyz/"]
    let fuzzy = ["derive/^([zcs])h/$1/", "derive/ang$/an/", "derive/^huang$/wang/"]

    let current = fuzzy + alwaysOn + userOwn
    let base = current.filter { !RimeIceConfigStore.fuzzyRuleSet.contains($0) }
    XCTAssertEqual(base, alwaysOn + userOwn, "常驻规则与用户规则被误判为模糊音")

    let selected = RimeIceConfigStore.fuzzyRules.map(\.rule)
      .filter { Set(fuzzy).contains($0) }
    // 已选模糊音必须前置到 base 之前（与出厂 algebra 中模糊音段的位置一致）
    let merged = selected + base
    XCTAssertEqual(Array(merged.prefix(fuzzy.count)).sorted(), fuzzy.sorted())
    XCTAssertEqual(Array(merged.suffix(base.count)), base)
  }

  // MARK: - 自定义短语：空条目

  /// 界面上点了「+」但没填内容就保存，不应向 tabledb 写入只含制表符的空行。
  func testEmptyPhraseEntryIsNotWrittenAsBlankTabLine() throws {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "phrase-empty-\(UUID().uuidString).txt")
    defer {
      try? FileManager.default.removeItem(at: url)
      try? FileManager.default.removeItem(at: url.appendingPathExtension("bak"))
    }
    var file = CustomPhraseFile(fileURL: url)
    file.addEntry()
    try file.save()

    let text = try String(contentsOf: url, encoding: .utf8)
    let junk = text.components(separatedBy: .newlines).filter {
      !$0.isEmpty && $0.trimmingCharacters(in: .whitespaces).isEmpty
    }
    XCTAssertTrue(junk.isEmpty, "写入了只含制表符的空条目行：\(junk)")
  }

  // MARK: - ④ keyBindings 判等（P1-1 修复须覆盖全局入口）

  /// `.keyBindings` 与 `.mapList` 共用 `valueEqual` 全局入口，且 key_bindings 的每条
  /// 也带数组字段（如 `accept: [String]`）。P1-1 修复后必须可比较相等，否则
  /// keyBindings 面板的 isDirty 会像 switches 一样恒为真。
  func testKeyBindingsMapListEqualityHandlesArrayValues() {
    let a: [[String: Any]] = [
      ["key": "a", "accept": ["x", "y"], "send": "A"],
      ["key": "b", "accept": ["z"]]
    ]
    let b: [[String: Any]] = [
      ["key": "a", "accept": ["x", "y"], "send": "A"],
      ["key": "b", "accept": ["z"]]
    ]
    XCTAssertEqual(PatchValue.keyBindings(a), PatchValue.keyBindings(b),
                   "keyBindings 含数组字段必须可比较相等（P1-1 全局入口）")
    // 与 switches 共用同一 valueEqual，顺带确认二者行为一致
    let s1: [[String: Any]] = [["name": "ascii", "states": ["中", "Ａ"]]]
    let s2: [[String: Any]] = [["name": "ascii", "states": ["中", "Ａ"]]]
    XCTAssertEqual(PatchValue.mapList(s1), PatchValue.mapList(s2))
  }

  // MARK: - ⑤ 短语保存失败必须抛出（syncPhraseFile 静默吞错的反面证据）

  /// 把目录置为只读后 save() 必须抛错——证明 `syncPhraseFile()`（RimeIceConfigStore.swift:268）
  /// 里 `try? phrases.save()` 吞掉的，是一个真实会发生的失败；一旦吞掉且紧接着重指向，
  /// 未保存词条便静默蒸发（P1-2，已列为 Known Issue）。
  func testCustomPhraseFileSaveThrowsWhenDirectoryReadOnly() throws {
    let dir = FileManager.default.temporaryDirectory
      .appending(path: "phrase-ro-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                             ofItemAtPath: dir.path(percentEncoded: false))
      try? FileManager.default.removeItem(at: dir)
    }
    // 置只读（去掉属主写权限）
    try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                          ofItemAtPath: dir.path(percentEncoded: false))
    let url = dir.appending(path: "custom_phrase.txt")
    var file = CustomPhraseFile(fileURL: url)
    file.addEntry()
    XCTAssertThrowsError(try file.save(),
      "只读目录下 save() 必须抛错，否则 syncPhraseFile 的 try? 永远吞不掉真实失败")
  }

  // MARK: - ⑥ 双拼短语文件定向（P2-3 映射）

  /// 全拼用 custom_phrase.txt、双拼统一用 custom_phrase_double.txt。
  /// 该映射目前硬编码（已知 P3），此处钉住当前正确行为防回归。
  func testPhraseFileNameMapsDoublePinyinToDoubleFile() {
    XCTAssertEqual(RimeIceConfigStore.phraseFileName(forSchema: "rime_ice"), "custom_phrase.txt")
    XCTAssertEqual(RimeIceConfigStore.phraseFileName(forSchema: "double_pinyin_flypy"), "custom_phrase_double.txt")
    XCTAssertEqual(RimeIceConfigStore.phraseFileName(forSchema: "double_pinyin_mspy"), "custom_phrase_double.txt")
    XCTAssertEqual(RimeIceConfigStore.phraseFileName(forSchema: ""), "custom_phrase.txt")
  }

  // MARK: - ⑦ syncPhraseFile 直接行为（P1-2 修复的硬钉）

  /// 直接钉 `syncPhraseFile()` 的修复契约：保存失败时必须**暴露错误**且**阻止指针重指向**，
  /// 未保存词条留在编辑器，绝不静默蒸发（P1-2 终验）。
  ///
  /// 安全做法：把 `store.phrases` 重定向到一个**临时只读文件**，唯一会失败的写盘发生在我掌控的
  /// 临时目录（绝不碰真实 ~/Library/Rime）。保存失败后修复逻辑不应把指针挪到真实方案词典，
  /// 而应保留旧 `phrases` 并置 `phraseSaveError`。
  func testSyncPhraseFileSurfacesErrorAndBlocksRepointOnSaveFailure() throws {
    // 必须持有 SettingsStore 的强引用：RimeIceConfigStore.settings 是 unowned，
    // 传临时量会被 ARC 立即释放导致悬垂引用。
    let settings = SettingsStore()
    let store = RimeIceConfigStore(settings: settings)

    // 临时只读目录 + 其下的临时短语文件
    let dir = FileManager.default.temporaryDirectory
      .appending(path: "syncphrase-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                             ofItemAtPath: dir.path(percentEncoded: false))
      try? FileManager.default.removeItem(at: dir)
    }
    let tempURL = dir.appending(path: "phrases-readonly.txt")
    // 置只读：save() 在此目录必失败（同 testCustomPhraseFileSaveThrowsWhenDirectoryReadOnly 的机制）
    try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                          ofItemAtPath: dir.path(percentEncoded: false))

    // 在临时文件上造出 dirty 词条（填词+码，避开空条目过滤）
    var p = CustomPhraseFile(fileURL: tempURL)
    p.addEntry()
    if var line = p.lines.last {
      line.word = "词"
      line.code = "ci"
      p.update(line)
    }
    store.phrases = p
    XCTAssertTrue(store.phrases.isDirty, "前置：切换前 phrases 应处于 dirty")

    // 切到另一个拼音方案，触发 didSet → syncPhraseFile()
    let current = store.activePinyinSchemaID
    let target = (current == "rime_ice") ? "double_pinyin_flypy" : "rime_ice"
    store.activePinyinSchemaID = target

    // 失败必须暴露，不再静默吞掉
    XCTAssertNotNil(store.phraseSaveError, "保存失败必须暴露 phraseSaveError，不可静默丢弃")
    // 指针不得被重指向（仍指向临时文件，而非真实方案词典 custom_phrase(_double).txt）
    XCTAssertEqual(store.phrases.fileURL, tempURL, "保存失败不应把指针挪到新方案词典，否则词条蒸发")
    // 未保存词条仍在编辑器
    XCTAssertTrue(store.phrases.isDirty, "保存失败后未保存词条应原样保留在编辑器")
  }

  // MARK: - ⑧ 雪狼智能纠错（占位：引擎待重做，相关测试已移至归档）

}
