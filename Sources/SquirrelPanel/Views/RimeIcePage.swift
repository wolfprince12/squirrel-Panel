//
//  RimeIcePage.swift
//  Squirrel Panel
//
//  雾凇拼音 (rime-ice) 独立面板：
//  上半部分是包管理（安装/卸载/更新/检查更新），从「输入方案」面板迁移而来；
//  下半部分是雾凇拼音专属配置管理（v1.2.0 起逐步开放，本文件先落地「基础开关」）。

import SwiftUI

struct RimeIcePage: View {
  @EnvironmentObject var ice: RimeIceConfigStore
  @EnvironmentObject var settings: SettingsStore

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        PackageManagerSection()

        if ice.isInstalled {
          basicSection
        } else {
          notInstalledSection
        }
      }
      .padding(20)
    }
  }

  // MARK: - 未安装占位

  private var notInstalledSection: some View {
    SettingsGroup("riceice.config.title") {
      Label {
        Text("riceice.notInstalled")
          .font(.callout)
      } icon: {
        Image(systemName: "exclamationmark.triangle")
      }
      .foregroundStyle(.secondary)
    }
  }

  // MARK: - 基础开关

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

        Stepper(value: $ice.menuPageSize, in: 1...10) {
          HStack {
            Text("riceice.pageSize")
            Spacer()
            Text("\(ice.menuPageSize)").foregroundStyle(.secondary)
          }
        }

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
}
