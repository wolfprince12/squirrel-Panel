//
//  RootView.swift
//  Squirrel Panel
//

import SwiftUI

enum PanelSection: String, CaseIterable, Identifiable {
  case appearance, schemas, behavior, appOptions, dictionary, about

  var id: String { rawValue }

  var title: String {
    switch self {
    case .appearance: return "外观"
    case .schemas: return "输入方案"
    case .behavior: return "按键与行为"
    case .appOptions: return "应用适配"
    case .dictionary: return "词库与同步"
    case .about: return "关于"
    }
  }

  var symbol: String {
    switch self {
    case .appearance: return "paintpalette"
    case .schemas: return "character.book.closed"
    case .behavior: return "keyboard"
    case .appOptions: return "square.grid.2x2"
    case .dictionary: return "externaldrive"
    case .about: return "info.circle"
    }
  }

  var tint: Color {
    switch self {
    case .appearance: return .orange
    case .schemas: return .green
    case .behavior: return .indigo
    case .appOptions: return .blue
    case .dictionary: return .pink
    case .about: return .gray
    }
  }
}

struct RootView: View {
  @EnvironmentObject private var store: SettingsStore
  @State private var selection: PanelSection = .appearance
  @State private var showingYAML = false
  @State private var showingResetAlert = false

  var body: some View {
    NavigationSplitView {
      List(PanelSection.allCases, selection: $selection) { section in
        NavigationLink(value: section) {
          Label {
            Text(section.title)
          } icon: {
            Image(systemName: section.symbol)
              .foregroundStyle(section.tint)
          }
        }
      }
      .navigationSplitViewColumnWidth(196)
      .safeAreaInset(edge: .bottom) {
        Text("所有改动写入 custom.yaml 补丁，不会覆盖你手写的配置。")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 12)
          .padding(.bottom, 10)
          .fixedSize(horizontal: false, vertical: true)
      }
    } detail: {
      Group {
        switch selection {
        case .appearance: AppearancePage()
        case .schemas: SchemaPage()
        case .behavior: BehaviorPage()
        case .appOptions: AppOptionsPage()
        case .dictionary: DictionaryPage()
        case .about: AboutPage(showingResetAlert: $showingResetAlert)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .windowBackgroundColor))
      .safeAreaInset(edge: .top, spacing: 0) { banners }
      .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }
    .navigationTitle("鼠须管控制面板")
    .sheet(isPresented: $showingYAML) { YAMLInspector() }
    .alert("恢复默认设置？", isPresented: $showingResetAlert) {
      Button("取消", role: .cancel) {}
      Button("恢复默认", role: .destructive) { store.resetManagedSettings() }
    } message: {
      Text("将移除控制面板写入的全部配置项。你手写的其他补丁条目会保留，操作前会自动生成 .bak 备份。")
    }
  }

  // MARK: - 顶部提示条

  @ViewBuilder
  private var banners: some View {
    VStack(spacing: 0) {
      if !store.environment.isInstalled {
        Banner(kind: .warning,
               text: "未检测到鼠须管。设置仍可保存，安装后会自动生效。",
               action: ("前往下载", { NSWorkspace.shared.open(URL(string: "https://rime.im/download/")!) }))
      } else if !store.environment.isUserDirectoryReady {
        Banner(kind: .info,
               text: "鼠须管尚未初始化用户目录。首次保存时会自动创建 ~/Library/Rime。",
               action: nil)
      }
      if let warning = store.unparsableWarning {
        Banner(kind: .error, text: warning + " 为避免损坏配置，写入已禁用。",
               action: ("打开用户目录", { SquirrelBridge.reveal(RimeEnvironment.userDirectory) }))
      }
      if let error = store.lastError {
        Banner(kind: .error, text: error, action: nil)
      }
    }
  }

  // MARK: - 底部操作栏

  private var footer: some View {
    HStack(spacing: 10) {
      if store.isApplying {
        ProgressView().controlSize(.small)
      }
      Text(store.isDirty ? "有未应用的更改" : store.statusMessage)
        .font(.callout)
        .foregroundStyle(store.isDirty ? Color.orange : Color.secondary)
        .lineLimit(1)
      Spacer()
      if store.isDirty {
        Button("放弃更改") { store.revert() }
      }
      Button("查看 YAML") { showingYAML = true }
      Button("应用并重新部署") { store.apply() }
        .buttonStyle(.borderedProminent)
        .disabled(!store.isDirty || !store.canWrite)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.bar)
  }
}

// MARK: - 提示条

struct Banner: View {
  enum Kind { case info, warning, error }

  let kind: Kind
  let text: String
  var action: (String, () -> Void)?

  private var symbol: String {
    switch kind {
    case .info: return "info.circle.fill"
    case .warning: return "exclamationmark.triangle.fill"
    case .error: return "xmark.octagon.fill"
    }
  }

  private var tint: Color {
    switch kind {
    case .info: return .blue
    case .warning: return .orange
    case .error: return .red
    }
  }

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbol).foregroundStyle(tint)
      Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
      Spacer()
      if let action {
        Button(action.0, action: action.1).controlSize(.small)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 9)
    .background(tint.opacity(0.10))
    .overlay(alignment: .bottom) { Divider() }
  }
}
