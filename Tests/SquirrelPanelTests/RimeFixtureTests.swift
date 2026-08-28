//
//  RimeFixtureTests.swift
//  Squirrel Panel
//
//  在**临时目录的最小 fixture** 上跑的回归用例，不依赖运行机器是否装了鼠须管 / 雾凇拼音。
//
//  为什么要有这一套：RimeIceFactoryStateTests 里那批「出厂态不得落盘」的探针
//  全部 `XCTSkipUnless(store.isInstalled)`，而 GitHub `macos-15` runner 上既没有
//  Squirrel.app 也没有 ~/Library/Rime，于是它们在 CI 上一条都不跑（跳过仍算 0 failures，
//  流水线照样绿）。等于防「出厂值被快照进 *.custom.yaml」回潮的保护在 CI 上是 0。
//
//  这里通过 RimeEnvironment 的两个 DEBUG 注入点（testUserDirectoryOverride /
//  testEnvironmentOverride）把用户目录与 SharedSupport 重定向到临时目录，
//  自己造出厂 default.yaml 与 rime_ice.schema.yaml，让同样的断言在任何机器上都真跑。
//  生产代码结构未动，注入点只在 DEBUG 构建里存在。
//
//  覆盖的缺陷：
//    F1    出厂 switcher/save_options 被钉进 default.custom.yaml（升级冻结雷）；
//    T1-1  干净安装首次 apply 凭空生成只有注释头的空 rime_ice.custom.yaml；
//    H1    reload 不清短语保存错误横幅；
//    NEW-1 出厂开关态被整段写进 rime_ice.custom.yaml；
//    NEW-2 候选词数继承态被反向钉成方案级覆盖；
//    V121-3 雾凇面板改动传导不到 SettingsStore.isDirty（「应用及部署」点不动）；
//    V121-4 雾凇仍写方案级 menu/page_size（压过「按键与行为」的全局候选数）。
//

import XCTest
@testable import SquirrelPanel

@MainActor
final class RimeFixtureTests: XCTestCase {

  // MARK: - 出厂 fixture 内容

  /// 出厂 `default.yaml`（SharedSupport 里那份），只保留本套用例要用到的段
  private static let factoryDefaultYAML = """
    schema_list:
      - schema: rime_ice

    menu:
      page_size: 5

    switcher:
      caption: 「方案选单」
      hotkeys:
        - F4
        - Control+grave
      # 开关记忆：出厂把 6 个开关里的 5 个写进了 save_options
      save_options:
        - ascii_punct
        - traditionalization
        - emoji
        - full_shape
        - search_single_char
      fold_options: true
    """

  /// 出厂 `rime_ice.schema.yaml`，含 6 个 switches 与四个列表型托管段
  private static let factoryIceSchemaYAML = """
    schema:
      schema_id: rime_ice
      name: 雾凇拼音
      version: "fixture"
      dependencies:
        - melt_eng
        - radical_pinyin

    switches:
      - name: ascii_mode
        states: [ 中, A ]
        reset: 0
      - name: ascii_punct
        states: [ ，。, ，． ]
      - name: traditionalization
        states: [ 简, 繁 ]
        reset: 0
      - name: emoji
        states: [ 💀, 😄 ]
        reset: 1
      - name: full_shape
        states: [ 半角, 全角 ]
      - name: search_single_char
        states: [ 词, 单 ]
        reset: 0

    engine:
      translators:
        - punct_translator
        - script_translator
        - table_translator@melt_eng
        - table_translator@cn_en
        - table_translator@radical_lookup
      filters:
        - lua_filter@*corrector
        - lua_filter@*autocap_filter
        - lua_filter@*v_filter
        - lua_filter@*reduce_english_filter
        - lua_filter@*long_word_filter
        - simplifier@emoji
        - lua_filter@*pin_cand_filter
        - lua_filter@*search@radical_pinyin
        - reverse_lookup_filter@radical_reverse_lookup
        - uniquifier

    speller:
      algebra:
        - erase/^xx$/
        - derive/^([jqxy])u$/$1v/

    traditionalize:
      opencc_config: s2t.json
    """

  /// 出厂 save_options 名单（与上面的 fixture 保持一致，测试侧独立写一份，不复用被测代码）
  private static let factorySaveOptions = [
    "ascii_punct", "traditionalization", "emoji", "full_shape", "search_single_char"
  ]

  // MARK: - fixture 环境搭建

  /// 一套 fixture 的路径
  private struct Fixture {
    let root: URL
    let userDirectory: URL
    let sharedSupport: URL

    var iceCustomURL: URL { userDirectory.appending(path: "rime_ice.custom.yaml") }
    var defaultCustomURL: URL { userDirectory.appending(path: "default.custom.yaml") }
    var squirrelCustomURL: URL { userDirectory.appending(path: "squirrel.custom.yaml") }
  }

  /// 造一份最小 fixture 并把 RimeEnvironment 重定向过去。
  ///
  /// `appURL` 有意留空（未安装 Squirrel.app）：`configSources` 只认 userDirectory 与
  /// sharedSupportURL，与 appURL 无关，而 `isInstalled == false` 能让 `settings.apply()`
  /// 跳过 `SquirrelBridge.deploy`——测试绝不能真去执行部署命令。
  private func makeFixture(defaultCustomYAML: String? = nil,
                           iceCustomYAML: String? = nil) throws -> Fixture {
    let fm = FileManager.default
    let root = fm.temporaryDirectory
      .appending(path: "squirrel-panel-fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
    let userDirectory = root.appending(path: "Rime", directoryHint: .isDirectory)
    let sharedSupport = root.appending(path: "SharedSupport", directoryHint: .isDirectory)
    try fm.createDirectory(at: userDirectory, withIntermediateDirectories: true)
    try fm.createDirectory(at: sharedSupport, withIntermediateDirectories: true)

    try Self.factoryDefaultYAML.write(to: sharedSupport.appending(path: "default.yaml"),
                                      atomically: true, encoding: .utf8)
    try Self.factoryIceSchemaYAML.write(to: sharedSupport.appending(path: "rime_ice.schema.yaml"),
                                        atomically: true, encoding: .utf8)
    if let defaultCustomYAML {
      try defaultCustomYAML.write(to: userDirectory.appending(path: "default.custom.yaml"),
                                  atomically: true, encoding: .utf8)
    }
    if let iceCustomYAML {
      try iceCustomYAML.write(to: userDirectory.appending(path: "rime_ice.custom.yaml"),
                              atomically: true, encoding: .utf8)
    }

    RimeEnvironment.testUserDirectoryOverride = userDirectory
    RimeEnvironment.testEnvironmentOverride = RimeEnvironment(
      appURL: nil, version: nil, sharedSupportURL: sharedSupport)
    return Fixture(root: root, userDirectory: userDirectory, sharedSupport: sharedSupport)
  }

  /// 撤销注入并清掉临时目录（每个用例都必须在 defer 里调用）
  private func teardown(_ fixture: Fixture) {
    RimeEnvironment.clearTestOverrides()
    try? FileManager.default.removeItem(at: fixture.root)
  }

  /// 读文件文本；文件不存在返回 nil
  private func text(at url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
  }

  private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
  }

  /// 组一对已互相挂好的 Store（与 SquirrelPanelApp 的接线方式一致）
  private func makeStores() -> (SettingsStore, RimeIceConfigStore) {
    let settings = SettingsStore()
    let ice = RimeIceConfigStore(settings: settings)
    settings.rimeIce = ice
    return (settings, ice)
  }

  // MARK: - 前置：fixture 本身可用

  /// fixture 必须真的被读进来了，否则下面所有断言都是空转
  func testFixtureEnvironmentIsActuallyLoaded() throws {
    let fixture = try makeFixture()
    defer { teardown(fixture) }

    let (settings, ice) = makeStores()
    XCTAssertTrue(ice.isInstalled, "fixture 的 rime_ice.schema.yaml 没被解析到，后续断言全部失去意义")
    XCTAssertEqual(ice.switches.count, 6, "fixture 出厂开关应为 6 个")
    XCTAssertEqual(settings.pageSize, 5, "fixture default.yaml 的 menu/page_size 应被读到")
    XCTAssertEqual(Set(settings.savedSwitchOptions), Set(Self.factorySaveOptions),
                   "补丁没写过 save_options 时应回落出厂名单")
  }

  // MARK: - F1：出厂 save_options 不得落进 default.custom.yaml

  /// 干净安装（default.custom.yaml 不存在）下，编译结果里 switcher/save_options 必须是 nil。
  /// 只判空不判出厂的旧实现在这里必然写出出厂那 5 项。
  func testFactorySaveOptionsCompileToNil() throws {
    let fixture = try makeFixture()
    defer { teardown(fixture) }

    let settings = SettingsStore()
    XCTAssertEqual(Set(settings.savedSwitchOptions), Set(Self.factorySaveOptions),
                   "前置：出厂态下界面名单就是出厂名单")
    XCTAssertNil(settings.compileDefaultPatch()["switcher/save_options"] ?? nil,
                 "与出厂逐项相同的 save_options 必须写 nil；快照进补丁会让上游日后增删开关被静默压掉")
  }

  /// save_options 在 Rime 里是集合语义（只做 contains 判定），
  /// 顺序不同不代表用户改过内容，同样不得落盘。
  func testFactorySaveOptionsComparisonIsOrderInsensitive() throws {
    let fixture = try makeFixture()
    defer { teardown(fixture) }

    let settings = SettingsStore()
    settings.savedSwitchOptions = Self.factorySaveOptions.reversed()
    XCTAssertNil(settings.compileDefaultPatch()["switcher/save_options"] ?? nil,
                 "顺序不同但内容相同仍是出厂态，不得落盘")
  }

  /// 反向对照：名单与出厂不同（增一项 / 减一项）时必须照常写出，
  /// 防止为了修 F1 把这个键写成恒 nil——那会让用户的开关记忆设定落不了盘。
  func testNonFactorySaveOptionsAreStillWritten() throws {
    let fixture = try makeFixture()
    defer { teardown(fixture) }

    let settings = SettingsStore()

    // ① 多一项（用户额外记住 ascii_mode）
    let added = Self.factorySaveOptions + ["ascii_mode"]
    settings.savedSwitchOptions = added
    guard let value = settings.compileDefaultPatch()["switcher/save_options"] ?? nil else {
      return XCTFail("名单多出一项时必须写盘，否则用户的记忆设定丢失")
    }
    XCTAssertEqual(value, .stringList(added), "写出的名单必须与界面一致")

    // ② 少一项（用户把 emoji 设成固定默认，从记忆名单里摘除）
    let removed = Self.factorySaveOptions.filter { $0 != "emoji" }
    settings.savedSwitchOptions = removed
    XCTAssertEqual(settings.compileDefaultPatch()["switcher/save_options"] ?? nil,
                   .stringList(removed),
                   "名单少一项同样是偏离出厂，必须写盘")

    // ③ 全空仍写 nil：6 个开关都设成「固定」的既有设计，靠 rime_ice 的 reset 压过记忆
    settings.savedSwitchOptions = []
    XCTAssertNil(settings.compileDefaultPatch()["switcher/save_options"] ?? nil,
                 "空名单仍写 nil，回落出厂（既有设计，不得改动）")
  }

  /// 端到端：干净安装下点一次「应用」，落盘的 default.custom.yaml 里不得出现 save_options。
  func testApplyDoesNotSnapshotFactorySaveOptionsOntoDisk() throws {
    let fixture = try makeFixture()
    defer { teardown(fixture) }

    let (settings, _) = makeStores()
    XCTAssertNoThrow(try settings.performApplyWrites(), "fixture 下写盘不应出错")

    let written = try XCTUnwrap(text(at: fixture.defaultCustomURL), "应用后应写出 default.custom.yaml")
    XCTAssertFalse(written.contains("save_options"),
                   "出厂 save_options 被钉进补丁：上游 rime-ice 日后调整名单会被这份陈旧快照压掉")
    XCTAssertTrue(written.contains("menu/page_size"),
                  "对照：本面板真正托管的键仍要照常写出，证明 apply 确实生效了")
  }

  /// 老用户自愈：旧版本已把出厂名单写进 default.custom.yaml。
  /// ① 启动时不得被误判为「有未保存改动」；② 下次 apply 必须把该键删掉。
  func testStaleFactorySaveOptionsSnapshotIsNotDirtyAndSelfHeals() throws {
    let stale = """
      patch:
        menu/page_size: 5
        switcher/save_options:
          - ascii_punct
          - traditionalization
          - emoji
          - full_shape
          - search_single_char
      """
    let fixture = try makeFixture(defaultCustomYAML: stale)
    defer { teardown(fixture) }

    let (settings, _) = makeStores()
    XCTAssertEqual(Set(settings.savedSwitchOptions), Set(Self.factorySaveOptions),
                   "前置：补丁里写着出厂名单，界面读出来的就是它")
    XCTAssertFalse(settings.isDirty,
                   "老用户一启动就显示「有未保存更改」是惊吓；baseline 必须与编译结果同源")

    XCTAssertNoThrow(try settings.performApplyWrites())
    let healed = try XCTUnwrap(text(at: fixture.defaultCustomURL))
    XCTAssertFalse(healed.contains("save_options"), "下一次 apply 必须把陈旧的出厂快照删掉")
  }

  // MARK: - T1-1：干净安装不得凭空生成空的 rime_ice.custom.yaml

  /// 用户从没打开过雾凇面板，只在别处点了一次「应用」：
  /// 不该在家目录里多出一个只有注释头、没有任何 patch 段的 rime_ice.custom.yaml。
  func testCleanInstallApplyDoesNotCreateEmptyIceCustom() throws {
    let fixture = try makeFixture()
    defer { teardown(fixture) }

    let (settings, ice) = makeStores()
    XCTAssertTrue(ice.isInstalled, "前置：fixture 里雾凇方案是装好的")
    XCTAssertTrue(ice.compileIcePatch().values.allSatisfy { $0 == nil },
                  "前置：出厂态下一个托管键都不需要写")

    XCTAssertNoThrow(try settings.performApplyWrites())
    XCTAssertNil(settings.lastError)
    XCTAssertFalse(exists(fixture.iceCustomURL),
                   "无任何托管键要写时不得凭空创建 rime_ice.custom.yaml")
  }

  /// 反向对照：文件已存在时必须照常写盘——那是删除历史托管键的自愈路径，
  /// 跳过 save 会让旧版本写进去的 switches 快照永远清不掉。
  func testExistingIceCustomIsStillRewrittenForSelfHeal() throws {
    let stale = """
      patch:
        switches:
          - name: ascii_mode
            states: [ 中, A ]
            reset: 0
          - name: ascii_punct
            states: [ ，。, ，． ]
            reset: 0
      """
    let fixture = try makeFixture(iceCustomYAML: stale)
    defer { teardown(fixture) }

    let (settings, ice) = makeStores()
    XCTAssertTrue(ice.isInstalled)

    XCTAssertNoThrow(try settings.performApplyWrites())
    XCTAssertNil(settings.lastError)
    XCTAssertTrue(exists(fixture.iceCustomURL), "已存在的文件不得被跳过写盘")
    let healed = try XCTUnwrap(text(at: fixture.iceCustomURL))
    XCTAssertFalse(healed.contains("switches"),
                   "开关已回到出厂态，陈旧的 switches 快照必须被删掉（自愈路径）")
  }

  /// 用户真的改了开关时，文件该建还得建。
  func testIceCustomIsCreatedWhenThereIsSomethingToWrite() throws {
    let fixture = try makeFixture()
    defer { teardown(fixture) }

    let (settings, ice) = makeStores()
    // 把 ascii_punct 从「记忆」拨成「固定开」——偏离出厂，switches 段必须整段写回
    ice.switches = ice.switches.map { item in
      var copy = item
      if copy.name == "ascii_punct" { copy.mode = .on }
      return copy
    }
    XCTAssertNotNil(ice.compileIcePatch()["switches"] ?? nil, "前置：偏离出厂后应有内容要写")

    XCTAssertNoThrow(try settings.performApplyWrites())
    XCTAssertNil(settings.lastError)
    XCTAssertTrue(exists(fixture.iceCustomURL), "有托管键要写时必须落盘")
    let written = try XCTUnwrap(text(at: fixture.iceCustomURL))
    XCTAssertTrue(written.contains("switches"), "用户改动必须真的写进文件")
  }

  // MARK: - NEW-1 / NEW-2：这两条回归保护现在在 CI 上真跑

  /// 出厂开关态（5 项记忆 + 其余按 reset）编译结果里 switches 必须是 nil。
  func testFactorySwitchModesCompileToNoSwitchesSection() throws {
    let fixture = try makeFixture()
    defer { teardown(fixture) }

    let (_, ice) = makeStores()
    XCTAssertTrue(ice.switches.contains { $0.mode == .remember },
                  "前置：出厂 save_options 与雾凇开关必须有交集，否则覆盖不到 NEW-1")
    XCTAssertNil(ice.compileIcePatch()["switches"] ?? nil,
                 "出厂开关态必须写 nil；整段写回会把上游 switches 定格成陈旧快照")
  }

  /// 反向对照：任一项偏离出厂就必须整段写回全部 6 条（缺项等于删开关）。
  func testNonFactorySwitchModeStillWritesWholeSection() throws {
    let fixture = try makeFixture()
    defer { teardown(fixture) }

    let (_, ice) = makeStores()
    var items = ice.switches
    guard !items.isEmpty else { return XCTFail("出厂开关列表为空") }
    items[0].mode = (items[0].mode == .remember) ? .on : .remember
    ice.switches = items

    guard let value = ice.compileIcePatch()["switches"] ?? nil else {
      return XCTFail("有开关偏离出厂时必须整段写回，否则用户设定落不了盘")
    }
    guard case .mapList(let list) = value else {
      return XCTFail("switches 必须以 mapList 形式写回，实得 \(value)")
    }
    XCTAssertEqual(list.count, items.count, "整段写回必须包含全部开关")
  }

  /// 干净安装的整体快照：switches 与 menu/page_size 都必须是 nil，且不得判脏。
  func testCleanInstallCompilesNeitherSwitchesNorPageSize() throws {
    let fixture = try makeFixture()
    defer { teardown(fixture) }

    let (_, ice) = makeStores()
    let patch = ice.compileIcePatch()
    XCTAssertNil(patch["switches"] ?? nil, "干净安装不得写 switches 段（NEW-1 回潮）")
    XCTAssertNil(patch["menu/page_size"] ?? nil, "雾凇不得写 menu/page_size（NEW-2 回潮）")
    XCTAssertFalse(ice.isDirty, "刚 reload 完的干净安装不应被判为有未保存改动")
  }

  // MARK: - V121-4：候选词数只归「按键与行为」面板管

  /// 雾凇面板不再控制候选词数：无论全局怎么改、面板其它项是否有改动，
  /// `compileIcePatch()` 里的 `menu/page_size` 永远是 nil（= 删键，继承全局）。
  ///
  /// 方案级 `menu/page_size` 会压过全局，一旦被写出来，用户在「按键与行为」
  /// 面板改候选数对主力方案就完全无效——v1.2.0 的真实故障。
  func testRimeIceNeverWritesSchemaLevelPageSize() throws {
    let fixture = try makeFixture()
    defer { teardown(fixture) }

    let (settings, ice) = makeStores()

    // ① 出厂态
    XCTAssertNil(ice.compileIcePatch()["menu/page_size"] ?? nil,
                 "出厂态不得写方案级候选数覆盖")

    // ② 全局候选数怎么改都不写，也不得让雾凇面板凭空变脏
    let original = settings.pageSize
    settings.pageSize = original + 3
    XCTAssertNil(ice.compileIcePatch()["menu/page_size"] ?? nil,
                 "全局改动不得被反向钉成方案级覆盖，否则主力方案实际仍是旧值")
    XCTAssertFalse(ice.isDirty, "用户没碰雾凇面板，全局候选数改动不得让它凭空变脏")

    settings.pageSize = original
    XCTAssertNil(ice.compileIcePatch()["menu/page_size"] ?? nil)

    // ③ 面板别的项确实有改动、整份补丁要落盘时，仍然不带这个键
    ice.opencc = "s2hk.json"
    let patch = ice.compileIcePatch()
    XCTAssertNotNil(patch["traditionalize/opencc_config"] ?? nil,
                    "前置：得真有托管键要写，本断言才有意义")
    XCTAssertNil(patch["menu/page_size"] ?? nil,
                 "有改动要落盘时同样不得夹带方案级候选数覆盖")
  }

  /// 自愈：v1.2.0 曾允许在雾凇面板拨候选数，那批用户的 rime_ice.custom.yaml 里
  /// 躺着一个方案级 menu/page_size。升级后第一次「应用」必须把它删掉，
  /// 否则他们在「按键与行为」面板怎么改候选数都不生效。
  func testStaleSchemaLevelPageSizeIsRemovedOnApply() throws {
    let stale = """
      patch:
        menu/page_size: 9
      """
    let fixture = try makeFixture(iceCustomYAML: stale)
    defer { teardown(fixture) }

    let (settings, ice) = makeStores()
    XCTAssertTrue(ice.isInstalled, "前置：fixture 里雾凇方案是装好的")

    XCTAssertNoThrow(try settings.performApplyWrites())
    XCTAssertNil(settings.lastError, "fixture 下写盘不应出错")

    let healed = try XCTUnwrap(text(at: fixture.iceCustomURL), "文件已存在，不得跳过写盘")
    XCTAssertFalse(healed.contains("page_size"),
                   "遗留的方案级候选数覆盖必须被删掉，否则全局候选数设置永远无效")
  }

  // MARK: - V121-3：雾凇面板的改动必须能点亮「应用及部署」

  /// 底部操作栏的 `Button("button.applyDeploy").disabled(!store.isDirty ...)` 依赖
  /// `SettingsStore.isDirty`，而它含 `rimeIce?.isDirty`。这里钉住数据侧的传导：
  /// 动一下雾凇面板的任意 @Published，`settings.isDirty` 必须随之为真。
  ///
  /// （视图侧的另一半是 RootView 必须 `@EnvironmentObject var ice`——不订阅
  ///   RimeIceConfigStore，footer 不会重渲染，按钮就一直停在禁用态。）
  func testRimeIceEditMarksSettingsDirty() throws {
    let fixture = try makeFixture()
    defer { teardown(fixture) }

    let (settings, ice) = makeStores()
    XCTAssertFalse(settings.isDirty, "前置：干净安装刚 reload 完不应判脏")

    // 等价于在雾凇面板关掉「英文输入」开关
    ice.enableMeltEng.toggle()

    XCTAssertTrue(ice.isDirty, "雾凇面板自身必须先认得这次改动")
    XCTAssertTrue(settings.isDirty,
                  "雾凇改动必须传导到 SettingsStore.isDirty，否则「应用及部署」按钮点不动")
  }

  /// 反向对照：把改动改回去，脏标记必须落回干净，
  /// 防止为了修「按钮点不动」把 isDirty 写成恒真（那样按钮永远亮着，还原按钮也永远在）。
  func testRevertingRimeIceEditClearsSettingsDirty() throws {
    let fixture = try makeFixture()
    defer { teardown(fixture) }

    let (settings, ice) = makeStores()
    ice.enableMeltEng.toggle()
    XCTAssertTrue(settings.isDirty, "前置：改动后应判脏")

    ice.enableMeltEng.toggle()
    XCTAssertFalse(ice.isDirty, "改回原值后雾凇面板必须恢复干净")
    XCTAssertFalse(settings.isDirty, "改回原值后全局脏标记必须一起落回")
  }

  // MARK: - V121-2：未安装时配置区可见但置灰

  /// 未安装雾凇时，6 个开关行仍要展示出来（界面靠 `.disabled` 置灰），
  /// 但这批占位项绝不能被当成真实配置编译、落盘。
  func testUninstalledPreviewSwitchesAreShownButNeverWritten() throws {
    // 只造 default.yaml、不造 rime_ice.schema.yaml = 鼠须管在、雾凇没装
    let fm = FileManager.default
    let root = fm.temporaryDirectory
      .appending(path: "squirrel-panel-noice-\(UUID().uuidString)", directoryHint: .isDirectory)
    let userDirectory = root.appending(path: "Rime", directoryHint: .isDirectory)
    let sharedSupport = root.appending(path: "SharedSupport", directoryHint: .isDirectory)
    try fm.createDirectory(at: userDirectory, withIntermediateDirectories: true)
    try fm.createDirectory(at: sharedSupport, withIntermediateDirectories: true)
    try Self.factoryDefaultYAML.write(to: sharedSupport.appending(path: "default.yaml"),
                                      atomically: true, encoding: .utf8)
    RimeEnvironment.testUserDirectoryOverride = userDirectory
    RimeEnvironment.testEnvironmentOverride = RimeEnvironment(
      appURL: nil, version: nil, sharedSupportURL: sharedSupport)
    defer {
      RimeEnvironment.clearTestOverrides()
      try? fm.removeItem(at: root)
    }

    let (settings, ice) = makeStores()
    XCTAssertFalse(ice.isInstalled, "前置：本 fixture 里雾凇是没装的")
    XCTAssertEqual(ice.switches.count, 6,
                   "未安装时也要把 6 个开关行摆出来（置灰），不能是空白一片")

    // 占位项一律不得进入编译结果，更不得落盘
    XCTAssertTrue(ice.compileIcePatch().isEmpty, "未安装时编译结果必须为空")
    XCTAssertFalse(ice.isDirty, "占位开关不得让面板凭空变脏")

    XCTAssertNoThrow(try settings.performApplyWrites())
    XCTAssertNil(settings.lastError)
    XCTAssertFalse(exists(userDirectory.appending(path: "rime_ice.custom.yaml")),
                   "雾凇没装就不该生成 rime_ice.custom.yaml，占位开关更不能被写出去")
  }

  // MARK: - H1：短语保存错误横幅不得穿越 reload

  /// 短语保存失败留下的红条，用户点「还原」（settings.revert → reload）必须消失。
  /// reload 里给 activePinyinSchemaID 赋值时 isReloading 为真、didSet 被抑制，
  /// syncPhraseFile() 不执行 → 不显式清就永远挂着，只能重启 App。
  func testReloadClearsStalePhraseSaveError() throws {
    let fixture = try makeFixture()
    defer { teardown(fixture) }

    let (settings, ice) = makeStores()

    ice.phraseSaveError = "上一次保存失败"
    ice.reload()
    XCTAssertNil(ice.phraseSaveError, "reload 必须清掉陈旧的短语保存错误横幅")

    // 用户实际的操作路径：在主面板点「还原」
    ice.phraseSaveError = "上一次保存失败"
    settings.revert()
    XCTAssertNil(ice.phraseSaveError, "点「还原」后红条必须消失，否则只能重启 App")
  }
}
