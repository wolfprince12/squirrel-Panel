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

  var titleKey: String {
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

  var titleKey: String {
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
  let titleKey: String
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

// MARK: - AppKit 原生分类下拉（性能关键路径）

/// SwiftUI 的 `Picker` 在 body 求值时会为全部选项构建 SwiftUI 视图——
/// 候选窗按键编辑器每行 78 + 17 项、7 行就是约 700 个选项视图，
/// 是「按键与行为」面板打开延迟的根本来源（SwiftUI 差分/缓存均无法回避）。
///
/// 这里改用 AppKit 原生 `NSPopUpButton`：菜单项的创建是纳秒级 AppKit 操作，
/// 不进入 SwiftUI 视图树；交互形态（下拉 + 分类分组标题）保持完全一致。
private struct CategorizedPopupButton: NSViewRepresentable {
  struct Item { let id: String; let label: String }
  struct Group { let title: String; let items: [Item] }

  let groups: [Group]
  @Binding var selection: String

  func makeNSView(context: Context) -> NSPopUpButton {
    let button = NSPopUpButton(frame: .zero, pullsDown: false)
    button.bezelStyle = .texturedRounded
    button.lineBreakMode = .byTruncatingTail
    button.menu = Self.buildMenu(groups: groups, selection: selection)
    if let target = Self.item(in: button.menu, matching: selection) {
      button.select(target)
    }
    button.target = context.coordinator
    button.action = #selector(Coordinator.pick(_:))
    return button
  }

  func updateNSView(_ button: NSPopUpButton, context: Context) {
    context.coordinator.parent = self
    // 外部变化（载入预设 / 程序写入）时同步选中项，避免重建
    if (button.selectedItem?.representedObject as? String) == selection { return }
    if let target = Self.item(in: button.menu, matching: selection) {
      button.select(target)
    } else {
      // 不在清单中的自定义值（历史配置里的特殊 keysym）：重建菜单补上
      button.menu = Self.buildMenu(groups: groups, selection: selection)
      if let target = Self.item(in: button.menu, matching: selection) {
        button.select(target)
      }
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  final class Coordinator: NSObject {
    var parent: CategorizedPopupButton
    init(_ parent: CategorizedPopupButton) { self.parent = parent }

    @objc func pick(_ sender: NSPopUpButton) {
      parent.selection = sender.selectedItem?.representedObject as? String ?? parent.selection
    }
  }

  private static func buildMenu(groups: [Group], selection: String) -> NSMenu {
    let menu = NSMenu()
    var found = false
    for group in groups {
      // 分类标题：不可点的分组头（等同 SwiftUI Picker 的 Section header）
      let header = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
      header.isEnabled = false
      menu.addItem(header)
      for item in group.items {
        let mi = NSMenuItem(title: item.label, action: nil, keyEquivalent: "")
        mi.representedObject = item.id
        if item.id == selection { found = true }
        menu.addItem(mi)
      }
      menu.addItem(.separator())
    }
    if !found {
      // 自定义值（含空值）置顶追加，保证按钮始终有可显示的选中项
      let custom = NSMenuItem(title: selection.isEmpty ? "—" : selection,
                              action: nil, keyEquivalent: "")
      custom.representedObject = selection
      menu.insertItem(custom, at: 0)
    }
    return menu
  }

  private static func item(in menu: NSMenu?, matching selection: String) -> NSMenuItem? {
    guard let menu else { return nil }
    for mi in menu.items where (mi.representedObject as? String) == selection {
      return mi
    }
    return nil
  }
}

/// 「按键」下拉的分组数据（初始化一次，全部 AppKit 消费）
private let keyGroups: [CategorizedPopupButton.Group] = KeyCategory.allCases.map { cat in
  .init(title: NSLocalizedString(cat.titleKey, comment: ""),
        items: (keyOptionsByCategory[cat] ?? []).map { .init(id: $0.name, label: $0.name) })
}

/// 「动作」下拉的分组数据（本地化标签初始化一次）
private let sendGroups: [CategorizedPopupButton.Group] = SendCategory.allCases.map { cat in
  .init(title: NSLocalizedString(cat.titleKey, comment: ""),
        items: (sendActionsByCategory[cat] ?? []).map {
          .init(id: $0.id, label: NSLocalizedString($0.titleKey, comment: ""))
        })
}

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
  /// 候选窗按键编辑器（二级窗口）的显示开关
  @State private var showingCandidateKeysEditor = false

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
    .sheet(isPresented: $showingCandidateKeysEditor) {
      CandidateKeysEditor()
    }
  }

  // MARK: - 候选窗按键（概览 + 二级窗口编辑）

  private var candidateKeysSection: some View {
    SettingsGroup("behavior.candidateKeys.title") {
      VStack(alignment: .leading, spacing: 12) {
        Text("behavior.candidateKeys.hint")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 10) {
          Button {
            showingCandidateKeysEditor = true
          } label: {
            Label("behavior.candidateKeys.edit", systemImage: "keyboard.badge.ellipsis")
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          Spacer()
          Text(String(format: String(localized: "behavior.candidateKeys.count"),
                      store.candidateKeyBindings.count))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}

/// 候选窗按键绑定的一行（对应 squirrel.custom.yaml 的 key_bindings 元素）→ 键值表
private func rowsToBindings(_ rows: [KeyBindingRow]) -> [[String: Any]] {
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

/// 键值表 → 候选窗按键绑定的一行
private func bindingsToRows(_ bindings: [[String: Any]]) -> [KeyBindingRow] {
  bindings.map { dict in
    KeyBindingRow(
      when: (dict["when"] as? String) ?? "paging",
      accept: (dict["accept"] as? String) ?? "",
      send: (dict["send"] as? String) ?? "",
      toggle: (dict["toggle"] as? String) ?? ""
    )
  }
}

/// 候选窗按键编辑器（二级窗口）：主面板只留概览，编辑在 sheet 中进行，
/// 让「按键与行为」面板打开时不再构建大量下拉选项，彻底消除切换延迟。
private struct CandidateKeysEditor: View {
  @Environment(SettingsStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var rows: [KeyBindingRow] = []

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      toolbar
      columnHeaders
      rowsList
      Divider()
      footer
    }
    .frame(width: 680, height: 520)
    .onAppear { rows = bindingsToRows(store.candidateKeyBindings) }
    .onDisappear { store.candidateKeyBindings = rowsToBindings(rows) }
  }

  // MARK: - 标题栏

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "keyboard")
        .font(.title2)
        .foregroundStyle(.tint)
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 1) {
        Text("behavior.candidateKeys.title")
          .font(.headline)
        Text(String(format: String(localized: "behavior.candidateKeys.count"), rows.count))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("common.close") { dismiss() }
        .keyboardShortcut(.cancelAction)
        .controlSize(.small)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  // MARK: - 操作行

  private var toolbar: some View {
    HStack(spacing: 8) {
      Button {
        rows = bindingsToRows(defaultCandidateBindings)
      } label: {
        Label("behavior.candidateKeys.preset", systemImage: "square.and.arrow.down")
      }
      .controlSize(.small)

      Button {
        rows.append(KeyBindingRow())
      } label: {
        Label("behavior.candidateKeys.add", systemImage: "plus")
      }
      .controlSize(.small)
      .buttonStyle(.borderedProminent)

      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  // MARK: - 表头

  private var columnHeaders: some View {
    HStack(spacing: 8) {
      Text(LocalizedStringKey("behavior.candidateKeys.when"))
        .frame(width: 130, alignment: .leading)
      Text(LocalizedStringKey("behavior.candidateKeys.accept"))
        .frame(width: 150, alignment: .leading)
      Text(LocalizedStringKey("behavior.candidateKeys.send"))
        .frame(width: 190, alignment: .leading)
      Spacer()
    }
    .font(.caption.weight(.medium))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 18)
    .padding(.bottom, 6)
  }

  // MARK: - 表格

  private var rowsList: some View {
    ScrollView {
      LazyVStack(spacing: 8) {
        if rows.isEmpty {
          emptyState
        } else {
          ForEach($rows) { $row in
            KeyBindingRowView(row: $row) {
              rows.removeAll { $0.id == row.id }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
              RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
            )
          }
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
    }
  }

  private var emptyState: some View {
    VStack(spacing: 10) {
      Image(systemName: "keyboard.badge.ellipsis")
        .font(.system(size: 40))
        .foregroundStyle(.tertiary)
      Text("behavior.candidateKeys.empty")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 50)
  }

  // MARK: - 底部说明

  private var footer: some View {
    Text("behavior.candidateKeys.hint")
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
  }
}

/// 候选窗按键编辑器的一行（独立子视图，便于 SwiftUI 按行差分，缩小重绘范围）
private struct KeyBindingRowView: View {
  @Binding var row: KeyBindingRow
  let onDelete: () -> Void
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 8) {
      Picker("", selection: $row.when) {
        ForEach(WhenOption.all) { opt in
          Text(LocalizedStringKey(opt.titleKey)).tag(opt.id)
        }
      }
      .labelsHidden()
      .frame(width: 130)

      CategorizedPopupButton(groups: keyGroups, selection: $row.accept)
        .frame(width: 150)

      CategorizedPopupButton(groups: sendGroups, selection: $row.send)
        .frame(width: 190)

      Spacer()

      Button(action: onDelete) {
        Image(systemName: "minus.circle.fill")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.red)
      .opacity(hovering ? 1 : 0)
      .animation(.easeInOut(duration: 0.12), value: hovering)
      .help("generic.remove")
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .onHover { hovering = $0 }
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