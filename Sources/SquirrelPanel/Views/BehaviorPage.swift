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

/// 候选窗按键绑定的一行（对应 squirrel.custom.yaml 的 key_bindings 元素）
struct KeyBindingRow: Identifiable, Hashable {
  var id = UUID()
  var when: String = "paging"
  var accept: String = ""
  var send: String = ""
  var toggle: String = ""
}

/// key_bindings 的 `when` 取值（鼠须管候选窗 / 编辑过程的触发时机）
private let keyBindingWhenOptions = ["paging", "has_menu", "composing", "always", "predict"]

struct BehaviorPage: View {
  @EnvironmentObject private var store: SettingsStore
  /// 候选窗按键绑定的镜像行（实时写回 store，纳入统一「应用并重新部署」流程）
  @State private var keyBindingRows: [KeyBindingRow] = []

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
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
    .onChange(of: keyBindingRows) { _ in commitKeyBindings() }
  }

  // MARK: - 候选窗按键（P2：key_bindings 编辑器）

  private var candidateKeysSection: some View {
    SettingsGroup("behavior.candidateKeys.title") {
      VStack(alignment: .leading, spacing: 12) {
        Text("behavior.candidateKeys.hint")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack {
          Menu {
            Button("behavior.candidateKeys.preset.default") { loadPreset() }
          } label: {
            Label("behavior.candidateKeys.preset", systemImage: "square.and.arrow.down")
          }
          .controlSize(.small)
          Spacer()
        }

        if keyBindingRows.isEmpty {
          Text("behavior.candidateKeys.empty")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          // 表头
          HStack(spacing: 6) {
            Text(LocalizedStringKey("behavior.candidateKeys.when"))
              .font(.caption.weight(.medium))
              .frame(width: 158, alignment: .leading)
            Text(LocalizedStringKey("behavior.candidateKeys.accept"))
              .font(.caption.weight(.medium))
              .frame(width: 130, alignment: .leading)
            Text(LocalizedStringKey("behavior.candidateKeys.send"))
              .font(.caption.weight(.medium))
              .frame(width: 130, alignment: .leading)
            Text(LocalizedStringKey("behavior.candidateKeys.toggle"))
              .font(.caption.weight(.medium))
              .frame(width: 110, alignment: .leading)
            Spacer()
          }
          .foregroundStyle(.secondary)
          ForEach($keyBindingRows) { $row in
            HStack(spacing: 6) {
              Picker("", selection: $row.when) {
                ForEach(keyBindingWhenOptions, id: \.self) { opt in
                  Text(LocalizedStringKey("behavior.when.\(opt)")).tag(opt)
                }
              }
              .labelsHidden()
              .frame(width: 158)
              TextField("behavior.candidateKeys.accept", text: $row.accept)
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
              TextField("behavior.candidateKeys.send", text: $row.send)
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
              TextField("behavior.candidateKeys.toggle", text: $row.toggle)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
              Button {
                keyBindingRows.removeAll { $0.id == row.id }
              } label: {
                Image(systemName: "minus.circle.fill")
              }
              .buttonStyle(.plain)
              .foregroundStyle(.red)
              .help("generic.remove")
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
  }

  // MARK: - 候选窗按键：镜像行 ↔ Store

  private func load() {
    keyBindingRows = Self.bindingsToRows(store.candidateKeyBindings)
  }

  private func commitKeyBindings() {
    store.candidateKeyBindings = Self.rowsToBindings(keyBindingRows)
  }

  private func loadPreset() {
    keyBindingRows = Self.bindingsToRows(Self.candidatePreset)
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

  /// 常用候选窗键位（与鼠须管默认候选窗行为对齐的精简集）
  private static let candidatePreset: [[String: Any]] = [
    ["when": "paging", "accept": "comma", "send": "Page_Up"],
    ["when": "paging", "accept": "period", "send": "Page_Down"],
    ["when": "has_menu", "accept": "Return", "send": "commit_comment"],
    ["when": "has_menu", "accept": "Escape", "send": "cancel"],
    ["when": "has_menu", "accept": "space", "send": "commit"],
    ["when": "has_menu", "accept": "Up", "send": "Prev_On_List"],
    ["when": "has_menu", "accept": "Down", "send": "Next_On_List"]
  ]
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
