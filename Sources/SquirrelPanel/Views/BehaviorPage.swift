//
//  BehaviorPage.swift
//  Squirrel Panel
//

import SwiftUI

/// ascii_composer 的切换动作
private struct SwitchAction: Identifiable {
  let id: String
  let titleKey: String
  let detailKey: String

  static let all: [SwitchAction] = [
    .init(id: "commit_code", titleKey: "behavior.switch.commit_code", detailKey: "behavior.switch.commit_code.detail"),
    .init(id: "commit_text", titleKey: "behavior.switch.commit_text", detailKey: "behavior.switch.commit_text.detail"),
    .init(id: "clear", titleKey: "behavior.switch.clear", detailKey: "behavior.switch.clear.detail"),
    .init(id: "inline_ascii", titleKey: "behavior.switch.inline_ascii", detailKey: "behavior.switch.inline_ascii.detail"),
    .init(id: "noop", titleKey: "behavior.switch.noop", detailKey: "behavior.switch.noop.detail")
  ]
}

/// key_bindings 的 `when` 取值（鼠须管候选窗 / 编辑过程的触发时机）
private struct WhenOption: Identifiable {
  let id: String
  let titleKey: String

  static let all: [WhenOption] = [
    .init(id: "paging", titleKey: "behavior.when.paging"),
    .init(id: "has_menu", titleKey: "behavior.when.has_menu"),
    .init(id: "composing", titleKey: "behavior.when.composing"),
    .init(id: "always", titleKey: "behavior.when.always"),
    .init(id: "predict", titleKey: "behavior.when.predict")
  ]
}

/// `accept`（按键）下拉选单的分类（鼠须管 X11 keysym）
private enum KeyCategory: String, CaseIterable, Identifiable {
  case letter, digit, function, special, arrow, punctuation, modifier

  var id: String { rawValue }

  var titleKey: LocalizedStringKey {
    switch self {
    case .letter: return "behavior.key.category.letter"
    case .digit: return "behavior.key.category.digit"
    case .function: return "behavior.key.category.function"
    case .special: return "behavior.key.category.special"
    case .arrow: return "behavior.key.category.arrow"
    case .punctuation: return "behavior.key.category.punctuation"
    case .modifier: return "behavior.key.category.modifier"
    }
  }
}

/// `accept`（按键）下拉选项（Rime X11 keysym 名）
private struct KeyOption: Hashable, Identifiable {
  let name: String
  let category: KeyCategory
  var id: String { name }
}

/// `send`（动作）下拉选单的分类
private enum SendCategory: String, CaseIterable, Identifiable {
  case pageNavigation, listNavigation, commit, inputControl, ascii

  var id: String { rawValue }

  var titleKey: LocalizedStringKey {
    switch self {
    case .pageNavigation: return "behavior.sendAction.category.pageNavigation"
    case .listNavigation: return "behavior.sendAction.category.listNavigation"
    case .commit: return "behavior.sendAction.category.commit"
    case .inputControl: return "behavior.sendAction.category.inputControl"
    case .ascii: return "behavior.sendAction.category.ascii"
    }
  }
}

/// `send`（动作）下拉选项：Rime 命令名 + 本地化显示标签
private struct SendAction: Identifiable {
  let id: String
  let titleKey: LocalizedStringKey
  let category: SendCategory
}

/// 常用候选窗键位（与鼠须管默认候选窗行为对齐的精简集）
private let defaultCandidateBindings: [[String: Any]] = [
  ["when": "paging", "accept": "comma", "send": "Page_Up"],
  ["when": "paging", "accept": "period", "send": "Page_Down"],
  ["when": "has_menu", "accept": "Return", "send": "commit_comment"],
  ["when": "has_menu", "accept": "Escape", "send": "cancel"],
  ["when": "has_menu", "accept": "space", "send": "commit"],
  ["when": "has_menu", "accept": "Up", "send": "Prev_On_List"],
  ["when": "has_menu", "accept": "Down", "send": "Next_On_List"]
]

private let allKeyOptions: [KeyOption] =
  (["a","b","c","d","e","f","g","h","i","j","k","l","m","n","o","p","q","r","s","t","u","v","w","x","y","z"]
    .map { KeyOption(name: $0, category: .letter) })
  + (["0","1","2","3","4","5","6","7","8","9"]
    .map { KeyOption(name: $0, category: .digit) })
  + (["F1","F2","F3","F4","F5","F6","F7","F8","F9","F10","F11","F12"]
    .map { KeyOption(name: $0, category: .function) })
  + [
    KeyOption(name: "Tab", category: .special),
    KeyOption(name: "Return", category: .special),
    KeyOption(name: "Escape", category: .special),
    KeyOption(name: "space", category: .special),
    KeyOption(name: "BackSpace", category: .special),
    KeyOption(name: "Delete", category: .special),
    KeyOption(name: "Insert", category: .special),
    KeyOption(name: "Home", category: .special),
    KeyOption(name: "End", category: .special),
    KeyOption(name: "Page_Up", category: .special),
    KeyOption(name: "Page_Down", category: .special)
  ]
  + [
    KeyOption(name: "Up", category: .arrow),
    KeyOption(name: "Down", category: .arrow),
    KeyOption(name: "Left", category: .arrow),
    KeyOption(name: "Right", category: .arrow)
  ]
  + [
    KeyOption(name: "comma", category: .punctuation),
    KeyOption(name: "period", category: .punctuation),
    KeyOption(name: "semicolon", category: .punctuation),
    KeyOption(name: "apostrophe", category: .punctuation),
    KeyOption(name: "bracketleft", category: .punctuation),
    KeyOption(name: "bracketright", category: .punctuation),
    KeyOption(name: "slash", category: .punctuation),
    KeyOption(name: "backslash", category: .punctuation),
    KeyOption(name: "grave", category: .punctuation),
    KeyOption(name: "minus", category: .punctuation),
    KeyOption(name: "equal", category: .punctuation)
  ]
  + [
    KeyOption(name: "Shift+Tab", category: .modifier),
    KeyOption(name: "Shift+space", category: .modifier),
    KeyOption(name: "Control+space", category: .modifier),
    KeyOption(name: "Control+Shift+space", category: .modifier)
  ]

private let allSendActions: [SendAction] = [
  .init(id: "Page_Up", titleKey: "behavior.sendAction.Page_Up", category: .pageNavigation),
  .init(id: "Page_Down", titleKey: "behavior.sendAction.Page_Down", category: .pageNavigation),
  .init(id: "Prev_Page", titleKey: "behavior.sendAction.Prev_Page", category: .pageNavigation),
  .init(id: "Next_Page", titleKey: "behavior.sendAction.Next_Page", category: .pageNavigation),
  .init(id: "Home", titleKey: "behavior.sendAction.Home", category: .pageNavigation),
  .init(id: "End", titleKey: "behavior.sendAction.End", category: .pageNavigation),
  .init(id: "Prev_On_List", titleKey: "behavior.sendAction.Prev_On_List", category: .listNavigation),
  .init(id: "Next_On_List", titleKey: "behavior.sendAction.Next_On_List", category: .listNavigation),
  .init(id: "Prev_Whole_List", titleKey: "behavior.sendAction.Prev_Whole_List", category: .listNavigation),
  .init(id: "Next_Whole_List", titleKey: "behavior.sendAction.Next_Whole_List", category: .listNavigation),
  .init(id: "commit", titleKey: "behavior.sendAction.commit", category: .commit),
  .init(id: "commit_comment", titleKey: "behavior.sendAction.commit_comment", category: .commit),
  .init(id: "cancel", titleKey: "behavior.sendAction.cancel", category: .commit),
  .init(id: "clear", titleKey: "behavior.sendAction.clear", category: .inputControl),
  .init(id: "reset", titleKey: "behavior.sendAction.reset", category: .inputControl),
  .init(id: "noop", titleKey: "behavior.sendAction.noop", category: .inputControl),
  .init(id: "inline_ascii", titleKey: "behavior.sendAction.inline_ascii", category: .ascii)
]

/// 预分组缓存：把「按键 / 动作」选项按分类各分一次，供每个 Picker 直接复用。
/// 否则每行的 ForEach 都要对整份清单重复 `filter`（7 行 × 7 类 × 78 项），
/// 首次打开「按键与行为」面板时是明显的视图构建开销来源。
private let keyOptionsByCategory: [KeyCategory: [KeyOption]] = {
  var d: [KeyCategory: [KeyOption]] = [:]
  for cat in KeyCategory.allCases { d[cat] = allKeyOptions.filter { $0.category == cat } }
  return d
}()

private let sendActionsByCategory: [SendCategory: [SendAction]] = {
  var d: [SendCategory: [SendAction]] = [:]
  for cat in SendCategory.allCases { d[cat] = allSendActions.filter { $0.category == cat } }
  return d
}()

/// 候选窗按键绑定的一行（对应 squirrel.custom.yaml 的 key_bindings 元素）
///
/// `toggle` 字段为历史数据保留：界面已不再显示「切换」列（避免歧义），
/// 但读取/写回时保留原值，避免破坏已存在的 toggle 绑定。
struct KeyBindingRow: Identifiable, Hashable {
  var id = UUID()
  var when: String = "paging"
  var accept: String = ""
  var send: String = ""
  var toggle: String = ""
}

struct BehaviorPage: View {
  @Environment(SettingsStore.self) private var store
  /// 候选窗按键绑定的镜像行（编辑时只改本地镜像，防抖后写回 store）
  @State private var keyBindingRows: [KeyBindingRow] = []
  /// 防抖提交任务：避免每输入一个字符就写回 store 触发全局重编译级联
  @State private var commitTask: Task<Void, Never>?

  var body: some View {
    @Bindable var store = store
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        SettingsGroup("behavior.candidates.title") {
          HStack {
            Text("behavior.pageSize")
            Spacer()
            Stepper(value: $store.pageSize, in: 1...10) {
              Text("\(store.pageSize)")
                .font(.callout.monospacedDigit())
                .frame(width: 24, alignment: .trailing)
            }
          }
          Text("behavior.pageSize.hint")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        SettingsGroup("behavior.switching.title") {
          Toggle("behavior.capsLock", isOn: $store.goodOldCapsLock)
          Text("behavior.capsLock.hint")
            .font(.caption)
            .foregroundStyle(.secondary)
          Divider()
          SwitchKeyRow(title: "behavior.switchKey.Caps_Lock", selection: $store.capsLockAction)
          SwitchKeyRow(title: "behavior.switchKey.Shift_L", selection: $store.shiftLeftAction)
          SwitchKeyRow(title: "behavior.switchKey.Shift_R", selection: $store.shiftRightAction)
          SwitchKeyRow(title: "behavior.switchKey.Control_L", selection: $store.controlLeftAction)
          SwitchKeyRow(title: "behavior.switchKey.Control_R", selection: $store.controlRightAction)
        }

        SettingsGroup("behavior.pagingKeys.title") {
          Toggle("behavior.pagingKeys.tab", isOn: $store.tabPagingEnabled)
          Text("behavior.pagingKeys.hint")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        SettingsGroup("behavior.system.title") {
          Picker("behavior.keyboardLayout", selection: $store.keyboardLayout) {
            Text("behavior.layout.last").tag("last")
            Text("behavior.layout.ABC").tag("com.apple.keylayout.ABC")
            Text("behavior.layout.USExtended").tag("com.apple.keylayout.USExtended")
            Text("behavior.layout.US").tag("com.apple.keylayout.US")
          }
          Picker("behavior.notifications", selection: $store.showNotificationsWhen) {
            Text("behavior.notifications.appropriate").tag("appropriate")
            Text("behavior.notifications.always").tag("always")
            Text("behavior.notifications.never").tag("never")
          }
        }

        SettingsGroup("behavior.quickActions") {
          HStack(spacing: 10) {
            Button("button.asciiMode") { SquirrelBridge.setASCIIMode(true) }
            Button("button.chineseMode") { SquirrelBridge.setASCIIMode(false) }
            Spacer()
            Button("button.restartSquirrel") {
              try? SquirrelBridge.restart(environment: store.environment)
            }
          }
          .disabled(!store.environment.isInstalled)
          Text("behavior.quickActions.hint")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        candidateKeysSection
      }
      .padding(20)
    }
    .onAppear(perform: load)
    .onDisappear {
      commitTask?.cancel()
      commitKeyBindings()
    }
    .onChange(of: keyBindingRows) { _, _ in scheduleCommit() }
  }

  /// 防抖写回：编辑期间只改本地镜像，停顿 300ms 后才写回 store。
  /// 避免每敲一个字符就触发一次全局补丁重编译（面板「黏手」的主要来源）。
  private func scheduleCommit() {
    commitTask?.cancel()
    commitTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 300_000_000)
      guard !Task.isCancelled else { return }
      commitKeyBindings()
    }
  }

  // MARK: - 候选窗按键（重设计：下拉选单 + 常驻表格 + 移除切换列）

  private var candidateKeysSection: some View {
    SettingsGroup("behavior.candidateKeys.title") {
      VStack(alignment: .leading, spacing: 12) {
        Text("behavior.candidateKeys.hint")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack {
          Button {
            loadDefaultPreset()
          } label: {
            Label("behavior.candidateKeys.preset", systemImage: "square.and.arrow.down")
          }
          .controlSize(.small)
          Spacer()
        }

        // 表头（始终显示）
        HStack(spacing: 6) {
          Text(LocalizedStringKey("behavior.candidateKeys.when"))
            .font(.caption.weight(.medium))
            .frame(width: 140, alignment: .leading)
          Text(LocalizedStringKey("behavior.candidateKeys.accept"))
            .font(.caption.weight(.medium))
            .frame(width: 150, alignment: .leading)
          Text(LocalizedStringKey("behavior.candidateKeys.send"))
            .font(.caption.weight(.medium))
            .frame(width: 170, alignment: .leading)
          Spacer()
        }
        .foregroundStyle(.secondary)

        ForEach($keyBindingRows) { $row in
          KeyBindingRowView(row: $row) {
            keyBindingRows.removeAll { $0.id == row.id }
          }
        }

        Button {
          keyBindingRows.append(KeyBindingRow())
        } label: {
          Label("behavior.candidateKeys.add", systemImage: "plus")
        }
        .controlSize(.small)
      }
    }
  }

  // MARK: - 候选窗按键：镜像行 ↔ Store

  private func load() {
    keyBindingRows = Self.bindingsToRows(store.candidateKeyBindings)
  }

  private func commitKeyBindings() {
    store.candidateKeyBindings = Self.rowsToBindings(keyBindingRows)
  }

  /// 重置为常用候选窗预设（覆盖当前编辑内容）
  private func loadDefaultPreset() {
    keyBindingRows = Self.bindingsToRows(defaultCandidateBindings)
  }

  private static func rowsToBindings(_ rows: [KeyBindingRow]) -> [[String: Any]] {
    rows.compactMap { row in
      let accept = row.accept.trimmingCharacters(in: .whitespaces)
      guard !accept.isEmpty else { return nil }
      var dict: [String: Any] = [
        "when": row.when.isEmpty ? "paging" : row.when,
        "accept": accept
      ]
      if !row.send.trimmingCharacters(in: .whitespaces).isEmpty {
        dict["send"] = row.send.trimmingCharacters(in: .whitespaces)
      }
      // 保留历史 toggle 绑定（界面已不暴露该列，但已存在配置不能丢）
      if !row.toggle.trimmingCharacters(in: .whitespaces).isEmpty {
        dict["toggle"] = row.toggle.trimmingCharacters(in: .whitespaces)
      }
      return dict
    }
  }

  private static func bindingsToRows(_ bindings: [[String: Any]]) -> [KeyBindingRow] {
    bindings.map { dict in
      KeyBindingRow(
        when: (dict["when"] as? String) ?? "paging",
        accept: (dict["accept"] as? String) ?? "",
        send: (dict["send"] as? String) ?? "",
        toggle: (dict["toggle"] as? String) ?? ""
      )
    }
  }
}

/// 候选窗按键编辑器的一行（独立子视图，便于 SwiftUI 按行差分，缩小重绘范围）
private struct KeyBindingRowView: View {
  @Binding var row: KeyBindingRow
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Picker("", selection: $row.when) {
        ForEach(WhenOption.all) { opt in
          Text(LocalizedStringKey(opt.titleKey)).tag(opt.id)
        }
      }
      .labelsHidden()
      .frame(width: 140)

      Picker("", selection: $row.accept) {
        ForEach(KeyCategory.allCases) { cat in
          Section {
            ForEach(keyOptionsByCategory[cat] ?? []) { opt in
              Text(opt.name).tag(opt.name)
            }
          } header: {
            Text(cat.titleKey)
          }
        }
      }
      .labelsHidden()
      .frame(width: 150)

      Picker("", selection: $row.send) {
        ForEach(SendCategory.allCases) { cat in
          Section {
            ForEach(sendActionsByCategory[cat] ?? []) { action in
              Text(action.titleKey).tag(action.id)
            }
          } header: {
            Text(cat.titleKey)
          }
        }
      }
      .labelsHidden()
      .frame(width: 170)

      Button(action: onDelete) {
        Image(systemName: "minus.circle.fill")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.red)
      .help("generic.remove")
    }
  }
}

private struct SwitchKeyRow: View {
  let title: String
  @Binding var selection: String

  var body: some View {
    HStack {
      Text(LocalizedStringKey(title))
      Spacer()
      Picker("", selection: $selection) {
        ForEach(SwitchAction.all) { action in
          Text(LocalizedStringKey(action.titleKey)).tag(action.id)
        }
      }
      .labelsHidden()
      .frame(width: 160)
      .help(SwitchAction.all.first { $0.id == selection }.map { LocalizedStringKey($0.detailKey) } ?? LocalizedStringKey(""))
    }
  }
}