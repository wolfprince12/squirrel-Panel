//
//  RootView.swift
//  Squirrel Panel
//

import SwiftUI

enum PanelSection: String, CaseIterable, Identifiable {
  case appearance, schemas, riceIce, behavior, appOptions, dictionary, about

  var id: String { rawValue }

  var title: LocalizedStringKey {
    switch self {
    case .appearance: return "nav.appearance"
    case .schemas: return "nav.schemas"
    case .riceIce: return "nav.riceIce"
    case .behavior: return "nav.behavior"
    case .appOptions: return "nav.appOptions"
    case .dictionary: return "nav.dictionary"
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
    case .about: return .gray
    }
  }
}

struct RootView: View {
  @EnvironmentObject private var store: SettingsStore
  /// 底部操作栏的启用态取决于 `store.isDirty`，而它含 `rimeIce?.isDirty`。
  /// `SettingsStore` 与 `RimeIceConfigStore` 是两个独立的 ObservableObject：
  /// 用户在雾凇面板改控件时只有 `ice` 的 @Published 变化，不订阅它的话
  /// `RootView.body`（footer 所在）不会重求值，「应用及部署」按钮会一直停在禁用态。
  /// 这里只为订阅变更通知而持有，不直接读取。
  @EnvironmentObject private var ice: RimeIceConfigStore
  @EnvironmentObject private var updateCenter: UpdateCenter
  @State private var selection: PanelSection = .appearance
  @State private var showingYAML = false
  @State private var showingResetAlert = false

  var body: some View {
    // 不再使用 NavigationSplitView：在 macOS + 英文系统 + PD 虚拟机环境下，
    // NavigationSplitView 的 sidebar 列会出现折叠/初始偏移 bug，只渲染后几项。
    // 改用显式 HStack 固定 sidebar 宽度，彻底消除 SwiftUI 自动分栏布局的不确定性。
    HStack(spacing: 0) {
      // MARK: Sidebar
      VStack(spacing: 0) {
        ScrollView(.vertical, showsIndicators: true) {
          VStack(spacing: 2) {
            ForEach(PanelSection.allCases) { section in
              Button(action: { selection = section }) {
                HStack(spacing: 10) {
                  Image(systemName: section.symbol)
                    .foregroundStyle(section.tint)
                    .frame(width: 20, alignment: .center)
                  Text(section.title)
                    .lineLimit(1)
                  Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .background(
                RoundedRectangle(cornerRadius: 6)
                  .fill(selection == section ? Color.accentColor.opacity(0.2) : Color.clear)
              )
              .foregroundStyle(selection == section ? .primary : .secondary)
            }
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        Text("footer.hint")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
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
          case .about: AboutPage(showingResetAlert: $showingResetAlert)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))

        footer
      }
    }
    .frame(minWidth: 880, minHeight: 620)
    .onAppear { updateCenter.checkAllOnLaunch() }
    .sheet(isPresented: $showingYAML) { YAMLInspector() }
    .alert("alert.resetTitle", isPresented: $showingResetAlert) {
      Button("alert.cancel", role: .cancel) {}
      Button("alert.reset", role: .destructive) { store.resetManagedSettings() }
    } message: {
      Text("alert.resetMessage")
    }
  }

  // MARK: - 顶部提示条

  @ViewBuilder
  private var banners: some View {
    VStack(spacing: 0) {
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
  }

  // MARK: - 底部操作栏

  private var footer: some View {
    HStack(spacing: 10) {
      if store.isApplying {
        ProgressView().controlSize(.small)
      }
      if store.isDirty {
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
      if store.isDirty {
        Button("button.revert") { store.revert() }
      }
      Button("button.viewYAML") { showingYAML = true }
      Button("button.applyDeploy") { store.apply() }
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
