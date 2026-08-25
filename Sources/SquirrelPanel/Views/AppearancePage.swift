//
//  AppearancePage.swift
//  Squirrel Panel
//

import SwiftUI
import AppKit

struct AppearancePage: View {
  @Environment(SettingsStore.self) private var store
  @State private var showSchemeEditor = false
  /// 自定义模块展示的「已启用方案」快照。
  /// UserColorSchemes.enabledSchemes() 是读盘静态函数：编辑器启用/禁用只改了磁盘注册表，
  /// SwiftUI 收不到状态变更通知、不会重绘。因此必须用 @State 持有快照，
  /// 并在弹窗关闭时重新读盘刷新，否则模块预览会停留在旧列表。
  @State private var enabledSchemes: [UserColorScheme] = UserColorSchemes.enabledSchemes()

  var body: some View {
    @Bindable var store = store
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        CandidatePreview()

        // 开发者（大狼）专属签名配色：独立模块，不混入总色卡网格
        SettingsGroup("appearance.scheme.developer.title") {
          Text("appearance.scheme.developer.hint")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 2)
          DeveloperSchemeGrid()
        }

        // 用户自定义配色：与系统/开发者网格一致的三列相对宽度，最多展示 3 张；
        // 不足 3 张时剩余位置显示「未配置方案」空白框。编辑入口统一移到底部居中。
        SettingsGroup("appearance.scheme.custom.title") {
          CustomSchemeGrid(enabledSchemes: enabledSchemes,
                           activeID: store.colorSchemeID) { id in
            store.colorSchemeID = id
          }
          Button(action: { showSchemeEditor = true }) {
            Label("appearance.scheme.custom.open", systemImage: "paintbrush.fill")
              .font(.system(size: 12, weight: .medium))
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .frame(maxWidth: .infinity)
          .help("appearance.scheme.custom.open")
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
                ForEach(enabledSchemes) { scheme in
                  let info = UserColorSchemes.info(for: scheme)
                  Text(info.name).tag(info.id)
                }
              }
            }
          }
        }

        SettingsGroup("appearance.font.title") {
          HStack(alignment: .center, spacing: 20) {
            FontFamilyPicker(selection: $store.fontFace, titleKey: "appearance.font.candidate", pickerWidth: nil)
            SliderRow(title: String(localized: "appearance.font.candidateSize"), value: $store.fontPoint, range: 10...36, step: 1, unit: "pt")
          }
          HStack(alignment: .center, spacing: 20) {
            FontFamilyPicker(selection: $store.labelFontFace, titleKey: "appearance.font.label", pickerWidth: nil)
            SliderRow(title: String(localized: "appearance.font.labelSize"), value: $store.labelFontPoint, range: 8...30, step: 1, unit: "pt")
          }
          HStack(alignment: .center, spacing: 20) {
            FontFamilyPicker(selection: $store.commentFontFace, titleKey: "appearance.font.comment", pickerWidth: nil)
            SliderRow(title: String(localized: "appearance.font.commentSize"), value: $store.commentFontPoint, range: 8...30, step: 1, unit: "pt")
          }
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
          SliderRow(title: String(localized: "appearance.layout.shadowSize"), value: $store.shadowSize, range: 0...24, step: 1, unit: "pt")
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
          Picker("appearance.behavior.statusMessage", selection: $store.statusMessageType) {
            Text("appearance.behavior.statusMessage.mix").tag("mix")
            Text("appearance.behavior.statusMessage.long").tag("long")
            Text("appearance.behavior.statusMessage.short").tag("short")
            Text("appearance.behavior.statusMessage.never").tag("never")
          }
          Text("appearance.behavior.statusMessage.hint")
            .font(.caption)
            .foregroundStyle(.secondary)
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
    // 首次出现用 @State 初始化的缓存值立即显示；进入页面后再异步刷新一次，
    // 避免 onAppear 同步读盘阻塞首帧（返回外观页时不再卡顿）。
    .task {
      enabledSchemes = UserColorSchemes.enabledSchemes()
    }
    .onChange(of: showSchemeEditor) { _, isShowing in
      // 弹窗关闭（启用/禁用/保存/编辑自定义方案后）重新读盘刷新模块展示，
      // 否则 SwiftUI 不会因磁盘注册表变更而重绘，预览会停留在旧列表。
      if !isShowing {
        enabledSchemes = UserColorSchemes.enabledSchemes()
      }
    }
    .sheet(isPresented: $showSchemeEditor) {
      UserColorSchemeEditor()
        .environment(store)
    }
  }

  /// 深色模式配色下拉列表中的「系统配色」分组：复用 store.systemColorSchemes（reload 时已算好）。
  private var systemDarkSchemes: [RimeColorSchemeInfo] {
    store.systemColorSchemes
  }

}

// MARK: - 配色色卡

struct ColorSchemeGrid: View {
  @Environment(SettingsStore.self) private var store

  private let columns = [
    GridItem(.flexible(), spacing: 10),
    GridItem(.flexible(), spacing: 10),
    GridItem(.flexible(), spacing: 10)
  ]

  var body: some View {
    LazyVGrid(columns: columns, spacing: 10) {
      // 系统配色网格：只含内置方案，绝不混入用户自定义方案。
      // 复用 store.systemColorSchemes（reload 时算好的派生数组），避免每次进面板重算 filter。
      ForEach(store.systemColorSchemes) { scheme in
        SchemeSwatch(scheme: scheme, isSelected: scheme.id == store.colorSchemeID)
          .onTapGesture { store.colorSchemeID = scheme.id }
      }
    }
  }
}

/// 开发者（大狼）专属配色的独立展示网格，点击即套用
struct DeveloperSchemeGrid: View {
  @Environment(SettingsStore.self) private var store

  private let columns = [
    GridItem(.flexible(), spacing: 10),
    GridItem(.flexible(), spacing: 10),
    GridItem(.flexible(), spacing: 10)
  ]

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
          .foregroundStyle(scheme.resolved.text)
        Text("1 鼠须管")
          .font(.system(size: 11))
          .foregroundStyle(scheme.resolved.highlightedCandidateText)
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(
            RoundedRectangle(cornerRadius: 3)
              .fill(scheme.resolved.highlightedCandidateBackground)
          )
        Text("2 输入法")
          .font(.system(size: 11))
          .foregroundStyle(scheme.resolved.candidateText)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
      .frame(height: 62)
      .background(scheme.resolved.background)

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

/// 自定义配色模块的三卡片网格：展示已启用方案（最多 3 张），
/// 不足 3 张时剩余位置渲染「未配置方案」空白框。与系统/开发者网格保持一致的相对宽度。
private struct CustomSchemeGrid: View {
  let enabledSchemes: [UserColorScheme]
  let activeID: String
  let onSelect: (String) -> Void

  private let columns = [
    GridItem(.flexible(), spacing: 10),
    GridItem(.flexible(), spacing: 10),
    GridItem(.flexible(), spacing: 10)
  ]

  var body: some View {
    LazyVGrid(columns: columns, spacing: 10) {
      // 已启用的方案：直接渲染可点选色卡
      ForEach(enabledSchemes) { scheme in
        let info = UserColorSchemes.info(for: scheme)
        let isActive = info.id == activeID
        SchemeSwatch(scheme: info, isSelected: isActive)
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
          .onTapGesture { onSelect(info.id) }
          .help("appearance.scheme.custom.tapToSelect")
      }
      // 不足 3 张：用空白占位框补齐，提示「未配置方案」
      ForEach(0..<max(0, 3 - enabledSchemes.count), id: \.self) { _ in
        CustomEmptySlot()
      }
    }
  }
}

/// 「未配置方案」空白预览框：复用 SchemeSwatch 骨架但内容置灰、居中显示提示。
private struct CustomEmptySlot: View {
  var body: some View {
    VStack(spacing: 0) {
      VStack {
        Spacer()
        Image(systemName: "plus.square.dashed")
          .font(.system(size: 22, weight: .regular))
          .foregroundStyle(.secondary)
        Text("appearance.scheme.custom.emptySlot")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.top, 4)
        Spacer()
      }
      .frame(maxWidth: .infinity)
      .frame(height: 62)
      .background(Color.primary.opacity(0.04))

      HStack {
        Text("appearance.scheme.custom.emptySlot")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
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
        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
    )
  }
}

// MARK: - 字体选择

struct FontFamilyPicker: View {
  @Binding var selection: String
  var titleKey: LocalizedStringKey = "appearance.font.candidate"
  var pickerWidth: CGFloat? = 240

  /// 474 个系统字体族若一次性塞进 Picker/PopUpButton，会在布局阶段同步测量全部
  /// Text 节点，主线程耗时 ~1.2s/次（切回外观页卡顿真凶）。改为点击弹出、带搜索过滤的
  /// popover + 懒加载列表：仅渲染可见项，且只在展开时构建，彻底消除同步重活；
  /// 用 popover 而非 Menu，规避 macOS Menu 内 ScrollView 按钮点击命中不可靠的坑。
  private static let families: [String] = {
    NSFontManager.shared.availableFontFamilies.sorted {
      $0.localizedStandardCompare($1) == .orderedAscending
    }
  }()

  @State private var isPresented = false
  @State private var query = ""

  private var filtered: [String] {
    let q = query.trimmingCharacters(in: .whitespaces).localizedLowercase
    guard !q.isEmpty else { return Self.families }
    return Self.families.filter { $0.localizedLowercase.contains(q) }
  }

  private var label: String {
    selection.isEmpty ? String(localized: "appearance.font.system") : selection
  }

  var body: some View {
    LabeledContent(titleKey) {
      Button {
        isPresented.toggle()
      } label: {
        HStack(spacing: 4) {
          Text(label)
            .lineLimit(1)
          Image(systemName: "chevron.down")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(minWidth: 160, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
      }
      .buttonStyle(.plain)
      .modifier(OptionalWidth(width: pickerWidth))
      .popover(isPresented: $isPresented, arrowEdge: .bottom) {
        FontPickerPopover(
          query: $query,
          selection: $selection,
          filtered: filtered,
          isPresented: $isPresented
        )
        .frame(width: 280, height: 340)
        .padding(8)
      }
    }
  }
}

/// 字体选择弹层：搜索框 + 懒加载列表。独立结构体便于在 popover 内稳定命中点击。
private struct FontPickerPopover: View {
  @Binding var query: String
  @Binding var selection: String
  let filtered: [String]
  @Binding var isPresented: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      TextField("appearance.font.search", text: $query)
        .textFieldStyle(.roundedBorder)
      Divider()
      // 系统默认项
      Button {
        selection = ""
        isPresented = false
      } label: {
        HStack {
          Text("appearance.font.system")
          Spacer()
          if selection.isEmpty { Image(systemName: "checkmark") }
        }
      }
      .buttonStyle(.plain)
      .padding(.vertical, 2)
      Divider()
      // 懒加载列表：仅渲染可见项，避免 474 项全量构建
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(filtered, id: \.self) { family in
            Button {
              selection = family
              isPresented = false
            } label: {
              HStack {
                Text(family)
                  .font(.custom(family, size: 13))
                Spacer()
                if family == selection { Image(systemName: "checkmark") }
              }
              .contentShape(Rectangle())
              .padding(.vertical, 3)
              .padding(.horizontal, 4)
            }
            .buttonStyle(.plain)
            .background(
              family == selection ? Color.accentColor.opacity(0.15) : Color.clear,
              in: Rectangle()
            )
          }
        }
      }
    }
  }
}

private struct OptionalWidth: ViewModifier {
  let width: CGFloat?
  func body(content: Content) -> some View {
    if let width {
      content.frame(width: width)
    } else {
      content.frame(maxWidth: .infinity)
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
      // lineLimit(1) + fixedSize：防止 HStack 空间紧张时被压缩竖排（如「字号」两个字）。
      Text(title)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
      Spacer(minLength: 8)
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
