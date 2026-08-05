//
//  RimeIceFactoryStateTests.swift
//  Squirrel Panel
//
//  「出厂态必须什么都不写」的真实安装探针，补上此前的测试盲区：
//  既有测试只验证了合并算法与判等，从没验证过 **compileIcePatch() 在干净安装下的整体输出**。
//  两个必现 bug 都藏在这个盲区里：
//    NEW-1 出厂即「记忆」的 5 个开关被误判为非出厂 → switches 整段永远被写进
//          rime_ice.custom.yaml（整段替换非追加），等于给上游 switches 拍永久快照；
//    NEW-2 候选词数被写成方案级覆盖 → 用户改全局候选数，雾凇面板凭空变脏且旧值
//          压过全局（方案级优先，用户改了个寂寞）。v1.2.1 起雾凇彻底不碰这个键。
//
//  这些用例一律**只读磁盘**：构造 SettingsStore / RimeIceConfigStore 只会读配置，
//  绝不调用 apply() / writePatch() / resetManagedRimeIce()，不会碰真实 ~/Library/Rime。
//

import XCTest
import Yams
@testable import SquirrelPanel

@MainActor
final class RimeIceFactoryStateTests: XCTestCase {

  // MARK: - 出厂事实（测试侧独立解析，不复用被测代码的私有缓存）

  /// 出厂 `default.yaml` 的 `switcher/save_options`
  private func factorySaveOptions(_ environment: RimeEnvironment) -> Set<String> {
    for url in environment.configSources(named: "default.yaml") {
      guard let text = try? String(contentsOf: url, encoding: .utf8),
            let object = try? Yams.load(yaml: text) as? [String: Any],
            let switcher = object["switcher"] as? [String: Any],
            let list = switcher["save_options"] as? [Any] else { continue }
      return Set(list.compactMap { $0 as? String })
    }
    return []
  }

  /// 出厂 `rime_ice.schema.yaml` 的 switches：name → reset（没写即 0）
  private func factoryResets(_ environment: RimeEnvironment) -> [String: Int] {
    let urls = environment.configSources(named: "rime_ice.schema.yaml")
    guard let url = urls.first(where: { !$0.pathComponents.contains("build") }),
          let text = try? String(contentsOf: url, encoding: .utf8),
          let object = try? Yams.load(yaml: text) as? [String: Any],
          let list = object["switches"] as? [[String: Any]] else { return [:] }
    var result: [String: Int] = [:]
    for item in list {
      guard let name = item["name"] as? String else { continue }
      result[name] = (item["reset"] as? Int) ?? 0
    }
    return result
  }

  /// 某开关的出厂模式：出厂 save_options 优先于 reset
  private func factoryMode(_ name: String,
                           saveOptions: Set<String>,
                           resets: [String: Int]) -> SwitchDefaultMode {
    saveOptions.contains(name) ? .remember : ((resets[name] == 1) ? .on : .off)
  }

  /// 本机 rime_ice.custom.yaml 是否已存在（存在即说明本机已被定制，
  /// 「干净安装」类断言不成立，应当跳过而不是假阳性失败）
  private var iceCustomExists: Bool {
    FileManager.default.fileExists(
      atPath: RimeEnvironment.userDirectory
        .appending(path: "rime_ice.custom.yaml").path(percentEncoded: false))
  }

  // MARK: - ① 出厂开关态必须写 nil（NEW-1）

  /// 把界面强制摆到出厂态（5 个记忆 + 其余按 reset），`compileIcePatch()` 的
  /// `switches` 必须是 nil。只按 `reset` 判定的旧实现在这里必然写出整段 6 条。
  func testFactorySwitchModesCompileToNoSwitchesSection() throws {
    let settings = SettingsStore()
    let store = RimeIceConfigStore(settings: settings)
    try XCTSkipUnless(store.isInstalled, "本机未安装 rime_ice.schema.yaml，跳过真实安装态探针")

    let saveOptions = factorySaveOptions(settings.environment)
    let resets = factoryResets(settings.environment)
    XCTAssertFalse(resets.isEmpty, "出厂 switches 解析为空，探针失去意义")

    store.switches = store.switches.map { item in
      var copy = item
      copy.mode = factoryMode(item.name, saveOptions: saveOptions, resets: resets)
      return copy
    }
    // 出厂态里必须确实存在「记忆」项，否则本机 default.yaml 与雾凇开关无交集，探不到 NEW-1
    XCTAssertTrue(store.switches.contains { $0.mode == .remember },
                  "出厂 save_options 与雾凇开关无交集，本用例无法覆盖 NEW-1")

    let patch = store.compileIcePatch()
    XCTAssertNil(patch["switches"] ?? nil,
                 "出厂开关态必须写 nil；整段写回会把上游 switches 定格成陈旧快照，升级即埋雷")
  }

  /// 反向对照：任何一项偏离出厂，switches 就必须整段写回（防止为了修 NEW-1 而写成恒 nil）
  func testNonFactorySwitchModeStillWritesWholeSection() throws {
    let settings = SettingsStore()
    let store = RimeIceConfigStore(settings: settings)
    try XCTSkipUnless(store.isInstalled, "本机未安装 rime_ice.schema.yaml，跳过真实安装态探针")

    let saveOptions = factorySaveOptions(settings.environment)
    let resets = factoryResets(settings.environment)
    var items = store.switches.map { item -> RimeIceSwitchItem in
      var copy = item
      copy.mode = factoryMode(item.name, saveOptions: saveOptions, resets: resets)
      return copy
    }
    guard let first = items.first else { return XCTFail("出厂开关列表为空") }
    // 把第一项拨离出厂态
    items[0].mode = (first.mode == .remember) ? .on : .remember
    store.switches = items

    guard let value = store.compileIcePatch()["switches"] ?? nil else {
      return XCTFail("有开关偏离出厂时必须整段写回 switches，否则用户的设定落不了盘")
    }
    guard case .mapList(let list) = value else {
      return XCTFail("switches 必须以 mapList 形式写回，实得 \(value)")
    }
    XCTAssertEqual(list.count, items.count, "整段写回必须包含全部开关，缺项等于删开关")
  }

  // MARK: - ② 干净安装的整体输出快照（NEW-1 + NEW-2 合并钉死）

  /// 真实安装探针：本机尚无 rime_ice.custom.yaml、且 save_options 未被改动时，
  /// 面板刚 reload 完的编译结果里 switches 与 menu/page_size 都必须是 nil，
  /// 且不得被判为「有未保存改动」——用户只在别的面板点一次「应用」，
  /// 也不该凭空生出一个 rime_ice.custom.yaml。
  func testCleanInstallCompilesNeitherSwitchesNorPageSize() throws {
    let settings = SettingsStore()
    let store = RimeIceConfigStore(settings: settings)
    try XCTSkipUnless(store.isInstalled, "本机未安装 rime_ice.schema.yaml，跳过真实安装态探针")
    try XCTSkipUnless(!iceCustomExists, "本机已存在 rime_ice.custom.yaml，非干净安装，跳过快照")

    // save_options 也必须仍是出厂名单，否则开关本就不在出厂态，断言不成立
    let saveOptions = factorySaveOptions(settings.environment)
    let saved = Set(settings.savedSwitchOptions)
    let names = Set(store.switches.map(\.name))
    try XCTSkipUnless(saved.intersection(names) == saveOptions.intersection(names),
                      "本机 switcher/save_options 已被定制，非干净安装，跳过快照")

    let patch = store.compileIcePatch()
    XCTAssertNil(patch["switches"] ?? nil,
                 "干净安装不得写 switches 段（NEW-1 回潮）")
    XCTAssertNil(patch["menu/page_size"] ?? nil,
                 "从没在本面板设过候选数 = 继承态，不得写 menu/page_size（NEW-2 回潮）")
    XCTAssertFalse(store.isDirty, "刚 reload 完的干净安装不应被判为有未保存改动")
  }

  // MARK: - ③ 候选词数只归「按键与行为」面板管（NEW-2 / V121-4）

  /// 改全局候选数（模拟「按键与行为」面板的操作，仅改内存不落盘）：
  /// 雾凇的 menu/page_size 必须仍写 nil，面板也不得因此变脏。
  func testGlobalPageSizeChangeKeepsRimeIceClean() throws {
    let settings = SettingsStore()
    let store = RimeIceConfigStore(settings: settings)
    try XCTSkipUnless(store.isInstalled, "本机未安装 rime_ice.schema.yaml，跳过真实安装态探针")
    try XCTSkipUnless(!iceCustomExists, "本机已存在 rime_ice.custom.yaml，无法保证处于出厂态，跳过")

    XCTAssertNil(store.compileIcePatch()["menu/page_size"] ?? nil, "前置：雾凇不应写 menu/page_size")
    let dirtyBefore = store.isDirty
    let original = settings.pageSize

    // 用户在别的面板把全局候选数改掉
    settings.pageSize = original + 1

    XCTAssertNil(store.compileIcePatch()["menu/page_size"] ?? nil,
                 "全局改动不得被反向钉成方案级覆盖，否则主力方案实际仍是旧值")
    XCTAssertEqual(store.isDirty, dirtyBefore,
                   "用户没碰雾凇面板，全局候选数改动不得让它凭空变脏")

    // 反方向也要成立：全局改回来同样不写
    settings.pageSize = original
    XCTAssertNil(store.compileIcePatch()["menu/page_size"] ?? nil)
  }

  /// 雾凇面板已彻底交出候选数控制权：即便面板别的项被改动、整份补丁要落盘，
  /// `menu/page_size` 也永远是 nil（= 删键，继承全局）。
  ///
  /// 方案级 `menu/page_size` 压过全局，只要它被写出来，「按键与行为」面板里的
  /// 候选数设置对主力方案就完全无效——v1.2.0 的真实故障。
  func testRimeIceNeverWritesSchemaLevelPageSize() throws {
    let settings = SettingsStore()
    let store = RimeIceConfigStore(settings: settings)
    try XCTSkipUnless(store.isInstalled, "本机未安装 rime_ice.schema.yaml，跳过真实安装态探针")

    XCTAssertNil(store.compileIcePatch()["menu/page_size"] ?? nil,
                 "前置：出厂态不得写方案级候选数覆盖")

    // 让面板真的有东西要写（只改内存，不落盘）
    store.opencc = (store.opencc == "s2t.json") ? "s2hk.json" : "s2t.json"
    let patch = store.compileIcePatch()
    XCTAssertNotNil(patch["traditionalize/opencc_config"] ?? nil,
                    "前置：得真有托管键要写，本断言才有意义")
    XCTAssertNil(patch["menu/page_size"] ?? nil,
                 "有改动要落盘时同样不得夹带方案级候选数覆盖")
  }

  // MARK: - ④ 陈旧的短语保存错误横幅必须能消失（NEW-4）

  /// 保存失败留下的红条，在用户把方案 Picker 切回同一词典文件时必须消失。
  /// 两个双拼共用 custom_phrase_double.txt，切换时会命中 `syncPhraseFile()` 的
  /// early-return——清错误若写在 guard 之后，红条就永远挂在界面上。
  func testStalePhraseSaveErrorClearsOnEarlyReturn() throws {
    let settings = SettingsStore()
    let store = RimeIceConfigStore(settings: settings)

    // 前置：短语编辑器无未保存内容，切换方案不会触发任何写盘
    XCTAssertFalse(store.phrases.isDirty, "前置：本用例不允许发生写盘，phrases 必须是干净的")

    store.activePinyinSchemaID = "double_pinyin_mspy"
    XCTAssertEqual(store.phrases.fileURL.lastPathComponent,
                   RimeIceConfigStore.phraseFileDoublePinyin)

    // 模拟上一次保存失败留下的红条
    store.phraseSaveError = "上一次保存失败"

    // 切到另一个双拼：目标词典文件与当前指针相同 → 命中 early-return
    store.activePinyinSchemaID = "double_pinyin_flypy"
    XCTAssertEqual(store.phrases.fileURL.lastPathComponent,
                   RimeIceConfigStore.phraseFileDoublePinyin,
                   "前置：两个双拼共用同一词典文件，本用例才能命中 early-return")
    XCTAssertNil(store.phraseSaveError,
                 "陈旧错误横幅必须在 early-return 之前清掉，否则红条永不消失")
    XCTAssertFalse(store.phrases.isDirty, "全程不应产生未保存内容")
  }
}
