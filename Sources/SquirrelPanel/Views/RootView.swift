//
//  RootView.swift
//  Squirrel Panel
//

import SwiftUI
import AppKit

enum PanelSection: String, CaseIterable, Identifiable {
  // 雪狼智能纠错模型置顶（核心入口）
  case snowWolf, appearance, schemas, riceIce, dictionary, behavior, backupSync, appOptions, maintenance, about

  var id: String { rawValue }

  var title: LocalizedStringKey {
    switch self {
    case .snowWolf: return "nav.snowWolfCorrection"
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
    case .snowWolf: return "brain"
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
    case .snowWolf: return .mint
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
  /// RootView 的 toolbar 与状态提示依赖 store.isDirty / statusMessage。
  /// `SettingsStore` 与 `RimeIceConfigStore` 是两个独立的 @Observable 数据源：
  /// 用户在雾凇面板改控件时只有 `ice` 的相关属性变化，不订阅它的话
  /// RootView body（toolbar 所在）不会重求值，「应用及部署」按钮会一直停在禁用态。
  /// 这里只为订阅变更通知而持有，不直接读取。
  @Environment(RimeIceConfigStore.self) private var ice
  @Environment(UpdateCenter.self) private var updateCenter
  @State private var selection: PanelSection = .snowWolf
  @State private var showingYAML = false

  private var allSections: [PanelSection] { PanelSection.allCases }

  private var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
  }

  var body: some View {
    // 2.2.0 起全面采用 macOS 系统设置 / Thaw 同款原生渲染：
    // - NavigationSplitView + List(selection:) + .listStyle(.sidebar) 获得原生侧边栏；
    // - 给 sidebar 列固定 min/ideal/max 宽度，规避英文系统 + PD 虚拟机下
    //   NavigationSplitView 折叠、只渲染后几项的布局 bug；
    // - .navigationTitle + .toolbar 获得原生标题与返回/前进/操作按钮；
    // - 左侧品牌区（logo + 应用名 + 版本号）置于 sidebar 顶部，沿用系统原生控件。
    NavigationSplitView {
      sidebar
    } detail: {
      detailContent
        .ignoresSafeArea(.container, edges: .top)
    }
    .frame(minWidth: 880, minHeight: 620)
    .onAppear {
      // 面板唤出时刷新一次（各模块自检轮询由菜单栏常驻进程在启动时统一触发）。
    }
    .sheet(isPresented: $showingYAML) { YAMLInspector() }
  }

  // MARK: - 侧边栏（原生 List + 顶部品牌区）

  private var sidebar: some View {
    VStack(spacing: 0) {
      List(selection: $selection) {
        Section {
          ForEach(PanelSection.allCases) { section in
            Label(section.title, systemImage: section.symbol)
              .listItemTint(section.tint)
              .tag(section)
          }
        } header: {
          sidebarBrand
        }
        .collapsible(false)
      }
      .listStyle(.sidebar)
      .toolbar(removing: .sidebarToggle)
      .toolbar { Color.clear }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      sidebarFooter
    }
    .frame(minWidth: 240, idealWidth: 240, maxWidth: 240)
    .navigationSplitViewColumnWidth(min: 240, ideal: 240, max: 240)
  }

  /// 品牌 logo：优先用 Resources/AppLogo.png（圆形，去掉 AppIcon 的圆角方底）；
  /// 若资源缺失则回退到 AppIcon。
  private static var appLogo: NSImage {
    if let url = Bundle.main.url(forResource: "AppLogo", withExtension: "png"),
       let image = NSImage(contentsOf: url) {
      return image
    }
    return NSApplication.shared.applicationIconImage ?? NSImage()
  }

  private var sidebarBrand: some View {
    VStack(alignment: .center, spacing: 10) {
      Image(nsImage: RootView.appLogo)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 96, height: 96)

      Text("v\(appVersion)")
        .font(.caption)
        .foregroundStyle(.secondary)

      Text("sidebar.brand.name")
        .font(.headline)
        .foregroundStyle(.primary)
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 16)
    .padding(.top, 8)
    .padding(.bottom, 12)
  }

  // MARK: - 详情区

  private var detailContent: some View {
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
        case .snowWolf: SnowWolfCorrectionPage()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  // MARK: - 侧边栏底部操作区（原顶部工具栏的按钮与状态迁移至此）

  private var sidebarFooter: some View {
    VStack(alignment: .center, spacing: 10) {
      // ① 应用状态信息文字
      HStack(spacing: 6) {
        if store.isApplying {
          ProgressView().controlSize(.small)
        }
        if store.isDirty {
          Text("footer.dirty")
            .font(.caption)
            .foregroundStyle(.orange)
        } else {
          Text(LocalizedStringKey(store.statusMessage))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      // ② 查看 YAML + 放弃更改 同排（保持原 HStack，不动这两个按钮样式）
      HStack(spacing: 8) {
        Button("button.viewYAML") { showingYAML = true }
          .controlSize(.small)
        Button("button.revert") { store.revert() }
          .controlSize(.small)
          .disabled(!store.isDirty)
      }

      // ③ 应用并重新部署 大按钮：固定宽度 140pt（按红线位置）+ 圆角矩形
      Button {
        store.apply()
      } label: {
        Text("button.applyDeploy")
          .font(.headline)
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .buttonBorderShape(.roundedRectangle(radius: 8))
      .controlSize(.large)
      .frame(width: 140)
      .disabled(!store.isDirty || !store.canWrite)

      // ④ 底部提示：本面板所有改动只写 custom.yaml 补丁，绝不覆盖用户手写的配置
      Text("footer.hint")
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 6)
    }
    // 让 footer 撑满 sidebar 整宽（240pt），里面按钮 width:240 才能真正填满
    .frame(maxWidth: .infinity, alignment: .center)
    .padding(.horizontal, 0)
    .padding(.vertical, 12)
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
