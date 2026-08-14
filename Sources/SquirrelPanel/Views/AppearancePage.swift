//
//  AppearancePage.swift
//  Squirrel Panel
//

import SwiftUI
import AppKit

struct AppearancePage: View {
  @EnvironmentObject private var store: SettingsStore
  @State private var showSchemeEditor = false
  /// 自定义模块当前展示的「用户确认方案」快照。
  /// confirmedScheme() 是读盘静态函数：编辑器点「使用此方案」只改了磁盘注册表，
  /// SwiftUI 收不到状态变更通知、不会重绘。因此必须用 @State 持有快照，
  /// 并在弹窗关闭时重新读盘刷新，否则模块预览会停留在旧方案。
  @State private var confirmedScheme: UserColorScheme? = UserColorSchemes.confirmedScheme()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        CandidatePreview()

        // 开发者（大狼）专属签名配色：独立模块，不混入总色卡网格
        SettingsGroup("appearance.scheme.developer.title") {
          Text("appearance.scheme.developer.hint")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 2)
          DeveloperSchemeGrid()
        }

        // 用户自定义配色：只展示「用户确认采用的」那一套方案，与全局选择完全独立
        SettingsGroup("appearance.scheme.custom.title") {
          HStack(alignment: .center, spacing: 16) {
            if let scheme = confirmedScheme {
              let info = UserColorSchemes.info(for: scheme)
              let isActive = store.colorSchemeID == scheme.id
              CustomSchemeCard(scheme: info, isActive: isActive) {
                store.colorSchemeID = scheme.id
              }
            } else {
              CustomEmptyState()
            }
            Spacer(minLength: 0)
            editorButton
          }
          .padding(.trailing, 140)
        }

        SettingsGroup("appearance.scheme.title") {
          ColorSchemeGrid()
          Toggle("appearance.scheme.followSystem", isOn: $store.followSystemAppearance)
            .padding(.top, 4)
          if store.followSystemAppearance {
            Picker("appearance.scheme.dark", selection: $store.colorSchemeDarkID) {
              Section("appearance.scheme.group.system") {
                ForEach(systemDarkSchemes) { scheme in
                  Text(scheme.name).tag(scheme.id)
                }
              }
              Section("appearance.scheme.group.developer") {
                ForEach(DeveloperColorSchemes.all) { scheme in
                  Text(scheme.name).tag(scheme.id)
                }
              }
              Section("appearance.scheme.group.custom") {
                if let confirmed = confirmedScheme {
                  let info = UserColorSchemes.info(for: confirmed)
                  Text(info.name).tag(info.id)
                }
              }
            }
          }
        }

        SettingsGroup("appearance.font.title") {
          FontFamilyPicker(selection: $store.fontFace)
          SliderRow(title: String(localized: "appearance.font.candidateSize"), value: $store.fontPoint, range: 10...36, step: 1, unit: "pt")
          SliderRow(title: String(localized: "appearance.font.labelSize"), value: $store.labelFontPoint, range: 8...30, step: 1, unit: "pt")
          SliderRow(title: String(localized: "appearance.font.commentSize"), value: $store.commentFontPoint, range: 8...30, step: 1, unit: "pt")
        }

        SettingsGroup("appearance.layout.title") {
          Picker("appearance.layout.arrangement", selection: $store.useLinearLayout) {
            Text("appearance.layout.vertical").tag(false)
            Text("appearance.layout.horizontal").tag(true)
          }
          .pickerStyle(.segmented)

          Picker("appearance.layout.textOrientation", selection: $store.useVerticalText) {
            Text("appearance.layout.horizontalText").tag(false)
            Text("appearance.layout.verticalText").tag(true)
          }
          .pickerStyle(.segmented)

          SliderRow(title: String(localized: "appearance.layout.cornerRadius"), value: $store.cornerRadius, range: 0...24, step: 1, unit: "pt")
          SliderRow(title: String(localized: "appearance.layout.hilitedCornerRadius"), value: $store.hilitedCornerRadius, range: 0...20, step: 1, unit: "pt")
          SliderRow(title: String(localized: "appearance.layout.lineSpacing"), value: $store.lineSpacing, range: 0...24, step: 1, unit: "pt")
          SliderRow(title: String(localized: "appearance.layout.preeditSpacing"), value: $store.preeditSpacing, range: 0...24, step: 1, unit: "pt")
          SliderRow(title: String(localized: "appearance.layout.borderWidth"), value: $store.borderWidth, range: 0...20, step: 1, unit: "pt")
          SliderRow(title: String(localized: "appearance.layout.borderHeight"), value: $store.borderHeight, range: 0...20, step: 1, unit: "pt")
          SliderRow(title: String(localized: "appearance.layout.alpha"), value: $store.alpha, range: 0.2...1, step: 0.05, unit: "")

          LabeledContent("appearance.layout.candidateFormat") {
            TextField("", text: $store.candidateFormat)
              .textFieldStyle(.roundedBorder)
              .frame(width: 240)
          }
          Text("appearance.layout.candidateFormat.hint")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        SettingsGroup("appearance.behavior.title") {
          Toggle("appearance.behavior.inlineCode", isOn: $store.inlinePreedit)
          Toggle("appearance.behavior.inlineCandidate", isOn: $store.inlineCandidate)
          Toggle("appearance.behavior.translucency", isOn: $store.translucency)
          Toggle("appearance.behavior.showPaging", isOn: $store.showPaging)
          Toggle("appearance.behavior.memorizeSize", isOn: $store.memorizeSize)
          Toggle("appearance.behavior.mutualExclusive", isOn: $store.mutualExclusive)
        }
      }
      .padding(20)
    }
    .onAppear { confirmedScheme = UserColorSchemes.confirmedScheme() }
    .onChange(of: showSchemeEditor) { isShowing in
      // 弹窗关闭（确认/保存/编辑自定义方案后）重新读盘刷新模块展示，
      // 否则 SwiftUI 不会因磁盘注册表变更而重绘，预览会停留在旧方案。
      if !isShowing {
        confirmedScheme = UserColorSchemes.confirmedScheme()
      }
    }
    .sheet(isPresented: $showSchemeEditor) {
      UserColorSchemeEditor()
        .environmentObject(store)
    }
  }

  /// 深色模式配色下拉列表中的「系统配色」分组：仅含内置方案。
  private var systemDarkSchemes: [RimeColorSchemeInfo] {
    store.colorSchemes.filter { !DeveloperColorSchemes.ids.contains($0.id) && !$0.isCustom }
  }

  private var editorButton: some View {
    Button(action: { showSchemeEditor = true }) {
      Label {
        Text("appearance.scheme.custom.open")
          .font(.system(size: 13, weight: .semibold))
      } icon: {
        Image(systemName: "paintbrush.fill")
          .font(.system(size: 16, weight: .semibold))
      }
    }
    .buttonStyle(.borderedProminent)
    .controlSize(.large)
    .frame(minWidth: 150, minHeight: 48)
    .clipShape(Capsule())
    .help("appearance.scheme.custom.open")
  }

}

// MARK: - 配色色卡

struct ColorSchemeGrid: View {
  @EnvironmentObject private var store: SettingsStore

  private let columns = [GridItem(.adaptive(minimum: 148), spacing: 10)]

  var body: some View {
    LazyVGrid(columns: columns, spacing: 10) {
      // 系统配色网格：只含内置方案，绝不混入用户自定义方案。
      // 自定义方案仅在「深色模式配色」下拉列表中单独显示（见 darkModeSchemes）。
      ForEach(store.colorSchemes.filter { !DeveloperColorSchemes.ids.contains($0.id) && !$0.isCustom }) { scheme in
        SchemeSwatch(scheme: scheme, isSelected: scheme.id == store.colorSchemeID)
          .onTapGesture { store.colorSchemeID = scheme.id }
      }
    }
  }
}

/// 开发者（大狼）专属配色的独立展示网格，点击即套用
struct DeveloperSchemeGrid: View {
  @EnvironmentObject private var store: SettingsStore

  private let columns = [GridItem(.adaptive(minimum: 148), spacing: 10)]

  var body: some View {
    LazyVGrid(columns: columns, spacing: 10) {
      ForEach(DeveloperColorSchemes.all) { scheme in
        let info = DeveloperColorSchemes.info(for: scheme)
        SchemeSwatch(scheme: info, isSelected: info.id == store.colorSchemeID, isDeveloper: true)
          .onTapGesture { store.colorSchemeID = scheme.id }
      }
    }
  }
}

struct SchemeSwatch: View {
  let scheme: RimeColorSchemeInfo
  let isSelected: Bool
  var isDeveloper: Bool = false

  @State private var isHovering = false

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 3) {
        Text("shu xu guan")
          .font(.system(size: 9))
          .foregroundStyle(scheme.color(scheme.text))
        Text("1 鼠须管")
          .font(.system(size: 11))
          .foregroundStyle(scheme.color(scheme.highlightedCandidateText))
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(
            RoundedRectangle(cornerRadius: 3)
              .fill(scheme.highlightedCandidateBackground.map { scheme.color($0) } ?? .clear)
          )
        Text("2 输入法")
          .font(.system(size: 11))
          .foregroundStyle(scheme.color(scheme.candidateText))
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
      .frame(height: 62)
      .background(scheme.color(scheme.background))

      HStack(spacing: 4) {
        Text(scheme.name)
          .font(.caption)
          .lineLimit(1)
          .truncationMode(.middle)
        if isDeveloper {
          Text("appearance.scheme.developer.badge")
            .font(.system(size: 9))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.22)))
        } else if scheme.isCustom {
          Text("appearance.scheme.custom")
            .font(.system(size: 9))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.16)))
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 7)
      .padding(.vertical, 5)
      .frame(maxWidth: .infinity)
      .background(Color(nsColor: .controlBackgroundColor))
    }
    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.10),
                      lineWidth: isSelected ? 2.5 : 0.5)
    )
    .contentShape(Rectangle())
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.12)) {
        isHovering = hovering
      }
    }
    .scaleEffect(isHovering && !isSelected ? 1.02 : 1.0)
    .shadow(color: .black.opacity(isHovering ? 0.10 : 0.04),
            radius: isHovering ? 6 : 2,
            y: isHovering ? 3 : 1)
    .help(scheme.author.map { String(format: String(localized: "appearance.scheme.author"), $0) } ?? scheme.id)
  }
}

// MARK: - 用户自定义配色模块组件

/// 自定义方案模块中的单卡：本身就是可点选主体，选中态用「使用中」角标表达，
/// 不再额外堆叠按钮。
private struct CustomSchemeCard: View {
  let scheme: RimeColorSchemeInfo
  let isActive: Bool
  let action: () -> Void

  var body: some View {
    SchemeSwatch(scheme: scheme, isSelected: isActive)
      .frame(width: 180)
      .overlay(alignment: .topTrailing) {
        if isActive {
          Text("appearance.scheme.custom.active")
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor))
            .foregroundStyle(.white)
            .padding(6)
        }
      }
      .contentShape(Rectangle())
      .onTapGesture(perform: action)
      .help("appearance.scheme.custom.tapToSelect")
  }
}

private struct CustomEmptyState: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Image(systemName: "paintbrush")
          .font(.title3)
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text("appearance.scheme.custom.empty.title")
            .font(.callout.weight(.medium))
          Text("appearance.scheme.custom.empty.subtitle")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 8)
  }
}

// MARK: - 字体选择

struct FontFamilyPicker: View {
  @Binding var selection: String

  private static let families: [String] = {
    NSFontManager.shared.availableFontFamilies.sorted {
      $0.localizedStandardCompare($1) == .orderedAscending
    }
  }()

  var body: some View {
    LabeledContent("appearance.font.candidate") {
      Picker("", selection: Binding(
        get: { Self.families.contains(selection) ? selection : "" },
        set: { selection = $0 }
      )) {
        Text("appearance.font.system").tag("")
        Divider()
        ForEach(Self.families, id: \.self) { family in
          Text(family).tag(family)
        }
      }
      .labelsHidden()
      .frame(width: 240)
    }
  }
}

// MARK: - 通用组件

struct SettingsGroup<Content: View>: View {
  let title: LocalizedStringKey
  @ViewBuilder let content: Content

  init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
        .padding(.leading, 2)
      VStack(alignment: .leading, spacing: 10) {
        content
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color(nsColor: .controlBackgroundColor))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(Color.primary.opacity(0.07))
      )
    }
  }
}

struct SliderRow: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let step: Double
  let unit: String

  var body: some View {
    HStack {
      Text(title)
      Spacer()
      Slider(value: $value, in: range, step: step)
        .frame(width: 190)
      Text(formatted)
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 46, alignment: .trailing)
    }
  }

  private var formatted: String {
    let text = step < 1 ? String(format: "%.2f", value) : String(Int(value.rounded()))
    return unit.isEmpty ? text : text + " " + unit
  }
}
