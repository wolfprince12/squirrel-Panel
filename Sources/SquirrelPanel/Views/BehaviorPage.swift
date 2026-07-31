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

struct BehaviorPage: View {
  @EnvironmentObject private var store: SettingsStore

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
      }
      .padding(20)
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
