//
//  AmethystCorrectionPage.swift
//  Squirrel Panel
//
//  「紫毫纠错模型」标签页：拼音实时纠错（规则 + 查表层）。
//
//  机制：同步、零延迟，与百度/搜狗同源——打字按错键（如 w 误触邻键 e，
//  woshi → eoshi）时，在第一条自然候选之后注入「纠错」候选，点选即填入。
//  不调用任何外部进程 / 模型，打字时确实生效。
//
//  纠错词表由离线生成器 tools/gen_correction_dict.py 从 rime-ice 词库全量产出：
//    对任意常见词的「相邻键 1 次错打」做精确查表，覆盖键盘邻键误触（如 w→e：woshi→eoshi）。
//
//  面板结构（2026-08-23 调整为上下两段）：
//    上：功能简介 + 使用逻辑 + 示例截图
//    下：纠错控制模块（总开关 + 候选位置 + 候选数量）
//

import SwiftUI
import AppKit

// MARK: - 主页面

struct AmethystCorrectionPage: View {
  @Environment(SettingsStore.self) private var store
  @Environment(UpdateCenter.self) private var updateCenter
  @Environment(RimeIceConfigStore.self) private var ice

  var body: some View {
    @Bindable var ice = ice
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        introSection
        controlSection
      }
      .padding(20)
    }
    // 不再设置 .navigationTitle：避免 macOS 窗口标题栏随选中项动态变化（与"鼠须管控制面板"顶栏冲突）。
  }

  // MARK: - 上段：功能简介 + 使用逻辑 + 示例截图

  private var introSection: some View {
    SettingsGroup("correction.intro.title") {
      VStack(alignment: .leading, spacing: 10) {
        Text("correction.intro")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        if let url = Bundle.main.url(forResource: "AmethystCorrectionDemo", withExtension: "png"),
           let nsImage = NSImage(contentsOf: url) {
          Image(nsImage: nsImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )
        }
      }
    }
  }

  // MARK: - 下段：纠错总开关 + 候选位置 + 候选数量

  @ViewBuilder
  private var controlSection: some View {
    @Bindable var ice = ice
    SettingsGroup("correction.control.title") {
      HStack(spacing: 12) {
        Toggle(isOn: $ice.correctionEnabled) {
          Text("correction.control.enable")
        }
        .toggleStyle(.switch)
        Spacer()
      }

      Text("correction.control.enable.desc")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if ice.correctionEnabled {
        Divider()
        LabeledContent("correction.position.title") {
          Picker("", selection: $ice.correctionInjectionPosition) {
            ForEach(CorrectionInjectionPosition.allCases) { p in
              Text(p.label).tag(p)
            }
          }
          .pickerStyle(.segmented)
          .frame(width: 300)
        }
        Text("correction.position.desc")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Divider()
        LabeledContent("correction.count.title") {
          Picker("", selection: $ice.correctionCandidateCount) {
            ForEach([1, 2, 3], id: \.self) { n in
              Text("\(n)").tag(n)
            }
          }
          .pickerStyle(.segmented)
          .frame(width: 300)
        }
        Text("correction.count.desc")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
