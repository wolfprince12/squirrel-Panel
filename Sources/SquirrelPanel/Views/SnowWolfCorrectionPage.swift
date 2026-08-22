//
//  SnowWolfCorrectionPage.swift
//  Squirrel Panel
//
//  「雪狼智能纠错模型」标签页：拼音实时纠错（规则 + 查表层）。
//
//  机制：同步、零延迟，与百度/搜狗同源——打字按错键（如 w 误触邻键 e，
//  woshi → eoshi）时，在第一条自然候选之后注入「纠错」候选，点选即填入。
//  不调用任何外部进程 / 模型，打字时确实生效。
//
//  两层噪声（由离线生成器产出词典）：
//    基础档：键盘相邻错打（QWERTY 邻键误触）。
//    标准档：相邻错打 + 系统性音近混淆（n↔l / r↔l / h↔f）。
//
//  进阶能力（规划中）：语法模型语境排序（类似万象，重排多条候选）、用户自学习。
//
//  面板结构：
//    1) 功能简介
//    2) 纠错总开关 + 强度
//    3) 纠错原理
//    4) 进阶能力路线图（规划中）
//

import SwiftUI
import AppKit

// MARK: - 通用依赖卡片（标题 + 描述 + 状态徽标 + 底部内容）

/// 与 PackageCard 保持一致的通用信息卡片：标题、描述、右上角状态、底部内容。
private struct DependencyCard<Status: View, Bottom: View>: View {
  let title: LocalizedStringKey
  let description: LocalizedStringKey
  @ViewBuilder let status: Status
  @ViewBuilder let bottom: Bottom

  var body: some View {
    SettingsGroup("") {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline) {
          Text(title).font(.headline)
          Spacer()
          status
        }
        Text(description)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        bottom
      }
    }
  }
}

// MARK: - 主页面

struct SnowWolfCorrectionPage: View {
  @Environment(SettingsStore.self) private var store
  @Environment(UpdateCenter.self) private var updateCenter
  @Environment(RimeIceConfigStore.self) private var ice

  var body: some View {
    @Bindable var ice = ice
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        introSection
        controlSection
        principleSection
        roadmapSection
      }
      .padding(20)
    }
    // 不再设置 .navigationTitle：避免 macOS 窗口标题栏随选中项动态变化（与"鼠须管控制面板"顶栏冲突）。
  }

  // MARK: - 1) 功能简介

  private var introSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("correction.intro")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - 2) 纠错总开关 + 强度

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
        LabeledContent("correction.strength.title") {
          Picker("", selection: $ice.correctionStrength) {
            ForEach(CorrectionStrength.allCases) { s in
              Text(s.label).tag(s)
            }
          }
          .pickerStyle(.segmented)
          .frame(width: 300)
        }
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
      }
    }
  }

  // MARK: - 3) 纠错原理

  private var principleSection: some View {
    DependencyCard(
      title: "correction.principle.title",
      description: "correction.principle.desc"
    ) {
      EmptyView()
    } bottom: {
      EmptyView()
    }
  }

  // MARK: - 4) 进阶能力路线图（规划中）

  @ViewBuilder
  private var roadmapSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("correction.roadmap.title").font(.headline)
      }

      DependencyCard(
        title: "correction.grammar.title",
        description: "correction.grammar.desc"
      ) {
        comingSoonBadge
      } bottom: {
        EmptyView()
      }

      DependencyCard(
        title: "correction.selflearn.title",
        description: "correction.selflearn.desc"
      ) {
        comingSoonBadge
      } bottom: {
        EmptyView()
      }
    }
  }

  private var comingSoonBadge: some View {
    Text("correction.comingSoon")
      .font(.caption2)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(Color.secondary.opacity(0.15))
      .foregroundStyle(.secondary)
      .clipShape(Capsule())
  }
}
