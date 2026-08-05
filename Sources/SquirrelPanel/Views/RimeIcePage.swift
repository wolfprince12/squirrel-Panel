//
//  RimeIcePage.swift
//  Squirrel Panel
//
//  雾凇拼音 (rime-ice) 独立面板：
//  上半部分是包管理（安装/卸载/更新/检查更新），从「输入方案」面板迁移而来；
//  下半部分是雾凇拼音专属配置管理——
//    · 基础开关（Phase B）：6 个三态开关（候选词数归「按键与行为」面板全局管理，本面板不碰）
//    · 词库与短语（Phase C）：英文/中英混合词/部件拆字/Emoji 词库 + 自定义短语编辑器
//    · 语言与拼音（Phase D）：繁体类型 + 全拼↔双拼切换 + 双拼编码原样显示
//    · 高级（Phase E）：Lua 滤镜开关 + 模糊音规则多选 + 直接编辑 rime_ice.custom.yaml
//

import SwiftUI

struct RimeIcePage: View {
  @EnvironmentObject var ice: RimeIceConfigStore
  @EnvironmentObject var settings: SettingsStore

  // 原始 YAML 编辑器状态
  @State private var rawExpanded = false
  @State private var rawText = ""
  @State private var rawError: String?
  @State private var rawMessage: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        // 包管理是安装入口，必须**始终可用**——把它一起置灰会让用户永远装不上雾凇。
        PackageManagerSection()

        if !ice.isInstalled {
          notInstalledBanner
        }

        // 未安装时配置区照常呈现（用户能看清面板到底提供哪些能力），整段置灰不可改。
        VStack(alignment: .leading, spacing: 20) {
          basicSection
          lexiconSection
          langSection
          advancedSection
        }
        .disabled(!ice.isInstalled)
      }
      .padding(20)
    }
  }

  // MARK: - 未安装提示横幅

  /// 未安装雾凇拼音时的醒目提示：下方配置区可见但不可改，装好后才生效。
  private var notInstalledBanner: some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text("riceice.notInstalled")
          .font(.callout)
        Text("riceice.notInstalled.disabledHint")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "info.circle")
        .foregroundStyle(Color.blue)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.blue.opacity(0.10))
    )
  }

  // MARK: - 基础开关（Phase B）

  private var basicSection: some View {
    SettingsGroup("riceice.basic.title") {
      VStack(alignment: .leading, spacing: 14) {
        Text("riceice.basic.hint")
          .font(.callout)
          .foregroundStyle(.secondary)

        ForEach($ice.switches) { $item in
          switchRow(item: $item)
          Divider()
        }

        // 候选词数**只**由「按键与行为」面板控制（全局 menu/page_size）。
        // 雾凇面板不再提供方案级覆盖，永远跟随全局。
        Text("riceice.saveOptions.note")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.top, 2)

        HStack {
          Spacer()
          Button("riceice.reset", role: .destructive) {
            ice.resetManagedRimeIce()
          }
          .controlSize(.small)
        }
      }
    }
  }

  private func switchRow(item: Binding<RimeIceSwitchItem>) -> some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(switchTitle(item.wrappedValue.name))
        if item.wrappedValue.states.count == 2 {
          Text("\(item.wrappedValue.states[0]) / \(item.wrappedValue.states[1])")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      Picker("", selection: item.mode) {
        ForEach(SwitchDefaultMode.allCases) { mode in
          Text(modeTitle(mode)).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .frame(width: 252)
    }
  }

  // MARK: - 词库与短语（Phase C）

  private var lexiconSection: some View {
    SettingsGroup("riceice.lexicon.title") {
      VStack(alignment: .leading, spacing: 12) {
        Text("riceice.lexicon.hint")
          .font(.callout)
          .foregroundStyle(.secondary)

        toggleRow(title: "riceice.lexicon.meltEng",
                  detail: "riceice.lexicon.meltEng.detail",
                  isOn: $ice.enableMeltEng)
        Divider()
        toggleRow(title: "riceice.lexicon.cnEn",
                  detail: "riceice.lexicon.cnEn.detail",
                  isOn: $ice.enableCnEn)
        Divider()
        toggleRow(title: "riceice.lexicon.radical",
                  detail: "riceice.lexicon.radical.detail",
                  isOn: $ice.enableRadical)
        Divider()
        toggleRow(title: "riceice.lexicon.emojiDict",
                  detail: "riceice.lexicon.emojiDict.detail",
                  isOn: $ice.enableEmojiDict)

        Divider().padding(.vertical, 2)
        phraseEditor
      }
    }
  }

  private var phraseEditor: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("riceice.phrase.title")
        .font(.callout)
        .fontWeight(.medium)
      Text("riceice.phrase.hint")
        .font(.caption)
        .foregroundStyle(.secondary)

      if let phraseSaveError = ice.phraseSaveError {
        HStack(spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill")
          Text(phraseSaveError).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.red.opacity(0.1))
        )
      }

      HStack(spacing: 8) {
        Text("riceice.phrase.word").frame(maxWidth: .infinity, alignment: .leading)
        Text("riceice.phrase.code").frame(width: 120, alignment: .leading)
        Text("riceice.phrase.weight").frame(width: 72, alignment: .leading)
        Color.clear.frame(width: 22, height: 1)
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      if ice.phrases.entryCount == 0 {
        Text("riceice.phrase.empty")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 8)
      } else {
        ScrollView {
          VStack(spacing: 6) {
            ForEach(ice.phrases.lines.filter(\.isEntry)) { line in
              phraseRow(id: line.id)
            }
          }
          .padding(.vertical, 2)
        }
        .frame(height: min(CGFloat(ice.phrases.entryCount) * 32 + 8, 220))
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
        )
      }

      HStack(spacing: 10) {
        Button {
          ice.phrases.addEntry()
        } label: {
          Label("riceice.phrase.add", systemImage: "plus")
        }
        .controlSize(.small)

        Spacer()

        Text(ice.phrases.fileURL.path(percentEncoded: false))
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)

        Button("riceice.phrase.save") {
          ice.phraseSaveError = nil
          settings.apply()
        }
        .controlSize(.small)
        .disabled(!ice.phrases.isDirty)
      }
    }
  }

  private func phraseRow(id: UUID) -> some View {
    let line = phraseBinding(id: id)
    return HStack(spacing: 8) {
      TextField("riceice.phrase.word", text: line.word)
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: .infinity)
      TextField("riceice.phrase.code", text: line.code)
        .textFieldStyle(.roundedBorder)
        .frame(width: 120)
      TextField("riceice.phrase.weight", text: line.weight)
        .textFieldStyle(.roundedBorder)
        .frame(width: 72)
      Button {
        ice.phrases.removeEntry(id: id)
      } label: {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(.borderless)
      .help("riceice.phrase.delete")
      .frame(width: 22)
    }
  }

  private func phraseBinding(id: UUID) -> Binding<PhraseLine> {
    Binding(
      get: { ice.phrases.lines.first(where: { $0.id == id }) ?? PhraseLine(id: id) },
      set: { newValue in ice.phrases.update(newValue) }
    )
  }

  // MARK: - 语言与拼音（Phase D）

  private var langSection: some View {
    SettingsGroup("riceice.lang.title") {
      VStack(alignment: .leading, spacing: 12) {
        Text("riceice.lang.hint")
          .font(.callout)
          .foregroundStyle(.secondary)

        HStack {
          Text("riceice.opencc")
          Spacer()
          Picker("", selection: $ice.opencc) {
            ForEach(RimeIceConfigStore.openccOptions, id: \.self) { option in
              Text(openccTitle(option)).tag(option)
            }
          }
          .labelsHidden()
          .frame(width: 260)
        }

        Divider()

        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text("riceice.pinyin.title")
            Text("riceice.pinyin.hint")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer()
          Picker("", selection: $ice.activePinyinSchemaID) {
            ForEach(ice.pinyinSchemaChoices) { schema in
              Text(schema.name).tag(schema.id)
            }
          }
          .labelsHidden()
          .frame(width: 260)
        }

        Divider()

        VStack(alignment: .leading, spacing: 3) {
          Toggle("riceice.pinyin.rawCode", isOn: $ice.showRawDoubleCode)
            .disabled(!ice.isDoublePinyinActive)
          Text(ice.isDoublePinyinActive ? "riceice.pinyin.rawCode.hint" : "riceice.pinyin.rawCode.unavailable")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  // MARK: - 高级（Phase E）

  private var advancedSection: some View {
    SettingsGroup("riceice.advanced.title") {
      VStack(alignment: .leading, spacing: 12) {
        Text("riceice.advanced.hint")
          .font(.callout)
          .foregroundStyle(.secondary)

        luaFilterBlock
        Divider()
        fuzzyBlock
        Divider()
        rawYAMLBlock
      }
    }
  }

  private var luaFilterBlock: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("riceice.lua.title")
        .font(.callout)
        .fontWeight(.medium)

      ForEach(RimeIceConfigStore.luaFilterKeys, id: \.self) { key in
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 2) {
            Toggle(luaTitle(key), isOn: luaBinding(key))
              .disabled(isLuaLocked(key))
            if isLuaLocked(key) {
              Text("riceice.lua.needEnglish")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          Spacer()
          Text("lua_filter@" + key)
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
        }
      }
    }
  }

  private var fuzzyBlock: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("riceice.fuzzy.title")
          .font(.callout)
          .fontWeight(.medium)
        Spacer()
        Text(String(format: String(localized: "riceice.fuzzy.count"), ice.fuzzySelection.count))
          .font(.caption)
          .foregroundStyle(.secondary)
        Button("riceice.fuzzy.clear") { ice.fuzzySelection.removeAll() }
          .controlSize(.small)
          .disabled(ice.fuzzySelection.isEmpty)
      }
      Text("riceice.fuzzy.hint")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      ForEach(FuzzyRuleGroup.allCases) { group in
        DisclosureGroup {
          LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                              GridItem(.flexible(), alignment: .leading)],
                    alignment: .leading, spacing: 4) {
            ForEach(RimeIceConfigStore.fuzzyRules.filter { $0.group == group }) { rule in
              Toggle(rule.label, isOn: fuzzyBinding(rule.rule))
                .font(.callout)
            }
          }
          .padding(.top, 4)
        } label: {
          Text(group.titleKey)
            .font(.callout)
        }
      }
    }
  }

  private var rawYAMLBlock: some View {
    DisclosureGroup(isExpanded: rawExpandedBinding) {
      VStack(alignment: .leading, spacing: 8) {
        Text("riceice.raw.hint")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        TextEditor(text: rawTextBinding)
          .font(.system(size: 12, design: .monospaced))
          .frame(height: 220)
          .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .strokeBorder(Color.primary.opacity(0.12))
          )

        if let rawError {
          Label {
            Text(String(format: String(localized: "riceice.raw.invalid"), rawError))
              .font(.caption)
          } icon: {
            Image(systemName: "xmark.octagon")
          }
          .foregroundStyle(Color.red)
        } else if let rawMessage {
          Text(rawMessage)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        HStack {
          Button("riceice.raw.reload") { loadRawYAML() }
            .controlSize(.small)
          Spacer()
          Text(ice.iceFileURL.path(percentEncoded: false))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
          Button("riceice.raw.apply") { applyRawYAML() }
            .controlSize(.small)
            .disabled(rawError != nil || !ice.canWrite)
        }
      }
      .padding(.top, 6)
    } label: {
      Text("riceice.raw.title")
        .font(.callout)
        .fontWeight(.medium)
    }
  }

  // MARK: - 原始 YAML 辅助

  private var rawExpandedBinding: Binding<Bool> {
    Binding(
      get: { rawExpanded },
      set: { expanded in
        rawExpanded = expanded
        if expanded { loadRawYAML() }
      }
    )
  }

  private var rawTextBinding: Binding<String> {
    Binding(
      get: { rawText },
      set: { newValue in
        rawText = newValue
        rawError = ice.validateRawIce(newValue)
        rawMessage = nil
      }
    )
  }

  private func loadRawYAML() {
    rawText = ice.rawIceText()
    rawError = ice.validateRawIce(rawText)
    rawMessage = nil
  }

  private func applyRawYAML() {
    do {
      try ice.saveRawIce(rawText)
      rawText = ice.rawIceText()
      rawError = nil
      rawMessage = String(localized: "riceice.raw.applied")
    } catch {
      rawMessage = error.localizedDescription
    }
  }

  // MARK: - 通用控件

  private func toggleRow(title: LocalizedStringKey,
                         detail: LocalizedStringKey,
                         isOn: Binding<Bool>) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Toggle(title, isOn: isOn)
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func luaBinding(_ key: String) -> Binding<Bool> {
    Binding(
      get: { ice.luaFilters[key] ?? true },
      set: { ice.luaFilters[key] = $0 }
    )
  }

  private func fuzzyBinding(_ rule: String) -> Binding<Bool> {
    Binding(
      get: { ice.fuzzySelection.contains(rule) },
      set: { isOn in
        if isOn {
          ice.fuzzySelection.insert(rule)
        } else {
          ice.fuzzySelection.remove(rule)
        }
      }
    )
  }

  /// autocap / reduce_english 与英文输入同生同死，英文关闭时禁止单独开启
  private func isLuaLocked(_ key: String) -> Bool {
    RimeIceConfigStore.englishBoundLuaFilters.contains(key) && !ice.enableMeltEng
  }

  // MARK: - 文案映射

  private func switchTitle(_ name: String) -> LocalizedStringKey {
    switch name {
    case "ascii_mode": return "riceice.switch.ascii_mode"
    case "ascii_punct": return "riceice.switch.ascii_punct"
    case "traditionalization": return "riceice.switch.traditionalization"
    case "emoji": return "riceice.switch.emoji"
    case "full_shape": return "riceice.switch.full_shape"
    case "search_single_char": return "riceice.switch.search_single_char"
    default: return LocalizedStringKey(name)
    }
  }

  private func modeTitle(_ mode: SwitchDefaultMode) -> LocalizedStringKey {
    switch mode {
    case .remember: return "riceice.mode.remember"
    case .on: return "riceice.mode.on"
    case .off: return "riceice.mode.off"
    }
  }

  private func openccTitle(_ option: String) -> LocalizedStringKey {
    switch option {
    case "s2t.json": return "riceice.opencc.s2t"
    case "s2hk.json": return "riceice.opencc.s2hk"
    case "s2tw.json": return "riceice.opencc.s2tw"
    case "s2twp.json": return "riceice.opencc.s2twp"
    default: return LocalizedStringKey(option)
    }
  }

  private func luaTitle(_ key: String) -> LocalizedStringKey {
    switch key {
    case "*corrector": return "riceice.lua.corrector"
    case "*autocap_filter": return "riceice.lua.autocap"
    case "*v_filter": return "riceice.lua.vFilter"
    case "*pin_cand_filter": return "riceice.lua.pinCand"
    case "*long_word_filter": return "riceice.lua.longWord"
    case "*reduce_english_filter": return "riceice.lua.reduceEnglish"
    default: return LocalizedStringKey(key)
    }
  }
}
