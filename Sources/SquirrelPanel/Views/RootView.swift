//
//  RootView.swift
//  Squirrel Panel
//

import SwiftUI

enum PanelSection: String, CaseIterable, Identifiable {
  case appearance, schemas, riceIce, dictionary, behavior, backupSync, appOptions, maintenance, about

  var id: String { rawValue }

  var title: LocalizedStringKey {
    switch self {
    case .appearance: return "nav.appearance"
    case .schemas: return "nav.schemas"
    case .riceIce: return "nav.riceIce"
    case .behavior: return "nav.behavior"
    case .appOptions: return "nav.appOptions"
    case .dictionary: return "nav.dictionary"
    case .maintenance: return "nav.maintenance"
    case .backupSync: return "nav.backupSync"
    case .about: return "nav.about"
    }
  }

  var symbol: String {
    switch self {
    case .appearance: return "paintpalette"
    case .schemas: return "character.book.closed"
    case .riceIce: return "tree"
    case .behavior: return "keyboard"
    case .appOptions: return "square.grid.2x2"
    case .dictionary: return "externaldrive"
    case .maintenance: return "wrench.and.screwdriver"
    case .backupSync: return "arrow.triangle.2.circlepath"
    case .about: return "info.circle"
    }
  }

  var tint: Color {
    switch self {
    case .appearance: return .orange
    case .schemas: return .green
    case .riceIce: return .teal
    case .behavior: return .indigo
    case .appOptions: return .blue
    case .dictionary: return .pink
    case .maintenance: return .purple
    case .backupSync: return .brown
    case .about: return .gray
    }
  }
}

struct RootView: View {
  @Environment(SettingsStore.self) private var store
  /// 底部操作栏的启用态取决于 `store.isDirty`，而它含 `rimeIce?.isDirty`。
  /// `SettingsStore` 与 `RimeIceConfigStore` 是两个独立的 @Observable 数据源：
  /// 用户在雾凇面板改控件时只有 `ice` 的相关属性变化，不订阅它的话
  /// `RootView.body`（footer 所在）不会重求值，「应用及部署」按钮会一直停在禁用态。
  /// 这里只为订阅变更通知而持有，不直接读取。
  @Environment(RimeIceConfigStore.self) private var ice
  @Environment(UpdateCenter.self) private var updateCenter
  @State private var selection: PanelSection = .appearance
  @State private var showingYAML = false

  var body: some View {
    // 不再使用 NavigationSplitView：在 macOS + 英文系统 + PD 虚拟机环境下，
    // NavigationSplitView 的 sidebar 列会出现折叠/初始偏移 bug，只渲染后几项。
    // 改用显式 HStack 固定 sidebar 宽度，彻底消除 SwiftUI 自动分栏布局的不确定性。
    HStack(spacing: 0) {
      // MARK: Sidebar
      VStack(spacing: 0) {
        ScrollView(.vertical, showsIndicators: true) {
          VStack(spacing: 2) {
            // 为窗口左上角红黄绿按钮留出顶部安全距离；用窗口背景色填充避免透色。
            Color(nsColor: .windowBackgroundColor)
              .frame(height: 40)

            ForEach(PanelSection.allCases) { section in
              SidebarItem(
                section: section,
                isSelected: selection == section,
                action: { selection = section }
              )
            }
          }
          .padding(.horizontal, 8)
          .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        Text("footer.hint")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .center)
          .background(Color(nsColor: .windowBackgroundColor))
      }
      .frame(width: 220)
      .background(Color(nsColor: .windowBackgroundColor))

      // MARK: Detail
      VStack(spacing: 0) {
        banners

        Group {
          switch selection {
          case .appearance: AppearancePage()
          case .schemas: SchemaPage()
          case .riceIce: RimeIcePage()
          case .behavior: BehaviorPage()
          case .appOptions: AppOptionsPage()
          case .dictionary: DictionaryPage()
          case .maintenance: MaintenancePage()
          case .backupSync: BackupSyncPage()
          case .about: AboutPage()
          }
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.16), value: selection)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))

        footer
      }
    }
    .frame(minWidth: 880, minHeight: 620)
    .ignoresSafeArea(.container, edges: .top)
    .onAppear { updateCenter.checkAllOnLaunch() }
    .sheet(isPresented: $showingYAML) { YAMLInspector() }
  }

  // MARK: - 侧边栏项目

  private struct SidebarItem: View {
    let section: PanelSection
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
      Button(action: action) {
        HStack(spacing: 10) {
          Image(systemName: section.symbol)
            .foregroundStyle(isSelected ? section.tint : section.tint.opacity(0.8))
            .frame(width: 20, alignment: .center)
          Text(section.title)
            .lineLimit(1)
          Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(isSelected
                  ? section.tint.opacity(0.12)
                  : (isHovering ? Color.primary.opacity(0.06) : Color.clear))
        )
        .overlay(alignment: .leading) {
          if isSelected {
            RoundedRectangle(cornerRadius: 1.5)
              .fill(section.tint)
              .frame(width: 3)
              .padding(.vertical, 6)
          }
        }
      }
      .buttonStyle(.plain)
      .foregroundStyle(isSelected ? .primary : .secondary)
      .onHover { hovering in
        withAnimation(.easeInOut(duration: 0.12)) {
          isHovering = hovering
        }
      }
    }
  }

  // MARK: - 顶部提示条

  @ViewBuilder
  private var banners: some View {
    VStack(spacing: 8) {
      if !store.environment.isInstalled {
        Banner(kind: .warning,
               text: String(localized: "banner.squirrelNotInstalled"),
               action: (String(localized: "banner.download"), { NSWorkspace.shared.open(URL(string: "https://rime.im/download/")!) }))
      } else if !store.environment.isUserDirectoryReady {
        Banner(kind: .info,
               text: String(localized: "banner.userDirNotReady"),
               action: nil)
      }
      if let warning = store.unparsableWarning {
        Banner(kind: .error,
               text: String(format: String(localized: "banner.unparsable"), warning),
               action: (String(localized: "banner.openUserDir"), { SquirrelBridge.reveal(RimeEnvironment.userDirectory) }))
      }
      if let error = store.lastError {
        Banner(kind: .error, text: error, action: nil)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  // MARK: - 底部操作栏

  private var footer: some View {
    // P0-1：isDirty 每次访问都会完整重编译三份补丁，footer 内原本读取 3 次。
    // 这里只取一次复用，避免随每一帧 / 每一个控件改动重复编译。
    let dirty = store.isDirty
    return HStack(spacing: 10) {
      if store.isApplying {
        ProgressView().controlSize(.small)
      }
      if dirty {
        Text("footer.dirty")
          .font(.callout)
          .foregroundStyle(Color.orange)
          .lineLimit(1)
      } else {
        Text(LocalizedStringKey(store.statusMessage))
          .font(.callout)
          .foregroundStyle(Color.secondary)
          .lineLimit(1)
      }
      Spacer()
      if dirty {
        Button("button.revert") { store.revert() }
      }
      Button("button.viewYAML") { showingYAML = true }
      Button("button.applyDeploy") { store.apply() }
        .buttonStyle(.borderedProminent)
        .disabled(!dirty || !store.canWrite)
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
    HStack(spacing: 12) {
      Image(systemName: symbol)
        .font(.callout)
        .foregroundStyle(tint)
        .frame(width: 26, height: 26)
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

      Text(text)
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)

      Spacer()

      if let action {
        Button(action.0, action: action.1)
          .controlSize(.small)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(tint.opacity(0.08))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(tint.opacity(0.18), lineWidth: 0.5)
    )
  }
}
