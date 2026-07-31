//
//  BehaviorPage.swift
//  Squirrel Panel
//

import SwiftUI

/// ascii_composer 的切换动作
private struct SwitchAction: Identifiable {
  let id: String
  let title: String
  let detail: String

  static let all: [SwitchAction] = [
    .init(id: "commit_code", title: "上屏编码", detail: "把已输入的拼音原样上屏后切换"),
    .init(id: "commit_text", title: "上屏候选", detail: "把当前候选词上屏后切换"),
    .init(id: "clear", title: "清空输入", detail: "丢弃已输入内容后切换"),
    .init(id: "inline_ascii", title: "临时英文", detail: "进入内嵌西文编辑模式"),
    .init(id: "noop", title: "不处理", detail: "该键不参与中英切换")
  ]
}

struct BehaviorPage: View {
  @EnvironmentObject private var store: SettingsStore

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        SettingsGroup("候选") {
          HStack {
            Text("每页候选数")
            Spacer()
            Stepper(value: $store.pageSize, in: 1...10) {
              Text("\(store.pageSize)")
                .font(.callout.monospacedDigit())
                .frame(width: 24, alignment: .trailing)
            }
          }
          Text("写入 default.custom.yaml 的 menu/page_size。部分输入方案会自行覆盖此项。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        SettingsGroup("中英文切换") {
          Toggle("Caps Lock 沿用系统大写锁定行为", isOn: $store.goodOldCapsLock)
          Text("开启后 Caps Lock 只切换大小写；关闭后它会被用作中英文切换键。")
            .font(.caption)
            .foregroundStyle(.secondary)
          Divider()
          SwitchKeyRow(title: "Caps Lock", selection: $store.capsLockAction)
          SwitchKeyRow(title: "左 Shift", selection: $store.shiftLeftAction)
          SwitchKeyRow(title: "右 Shift", selection: $store.shiftRightAction)
          SwitchKeyRow(title: "左 Control", selection: $store.controlLeftAction)
          SwitchKeyRow(title: "右 Control", selection: $store.controlRightAction)
        }

        SettingsGroup("系统集成") {
          Picker("键盘布局", selection: $store.keyboardLayout) {
            Text("沿用上次使用的布局").tag("last")
            Text("美式键盘 ABC").tag("com.apple.keylayout.ABC")
            Text("US Extended").tag("com.apple.keylayout.USExtended")
            Text("US（传统）").tag("com.apple.keylayout.US")
          }
          Picker("何时显示部署通知", selection: $store.showNotificationsWhen) {
            Text("仅必要时").tag("appropriate")
            Text("总是显示").tag("always")
            Text("从不显示").tag("never")
          }
        }

        SettingsGroup("快速操作") {
          HStack(spacing: 10) {
            Button("切换到英文") { SquirrelBridge.setASCIIMode(true) }
            Button("切换到中文") { SquirrelBridge.setASCIIMode(false) }
            Spacer()
            Button("重启鼠须管") {
              try? SquirrelBridge.restart(environment: store.environment)
            }
          }
          .disabled(!store.environment.isInstalled)
          Text("这些操作立即生效，不需要点「应用」。")
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
      Text(title)
      Spacer()
      Picker("", selection: $selection) {
        ForEach(SwitchAction.all) { action in
          Text(action.title).tag(action.id)
        }
      }
      .labelsHidden()
      .frame(width: 160)
      .help(SwitchAction.all.first { $0.id == selection }?.detail ?? "")
    }
  }
}
