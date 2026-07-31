//
//  RootView.swift
//  Squirrel Panel
//

import SwiftUI

enum PanelSection: String, CaseIterable, Identifiable {
  case appearance, schemas, behavior, appOptions, dictionary, about

  var id: String { rawValue }

  var title: LocalizedStringKey {
    switch self {
    case .appearance: return "nav.appearance"
    case .schemas: return "nav.schemas"
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
        Text("footer.hint")
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
    .navigationTitle("app.name")
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
