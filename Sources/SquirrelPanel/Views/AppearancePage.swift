//
//  AppearancePage.swift
//  Squirrel Panel
//

import SwiftUI
import AppKit

struct AppearancePage: View {
  @EnvironmentObject private var store: SettingsStore

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        CandidatePreview()

        SettingsGroup("配色方案") {
          ColorSchemeGrid()
          Toggle("跟随系统深浅色，深色模式使用另一套配色", isOn: $store.followSystemAppearance)
            .padding(.top, 4)
          if store.followSystemAppearance {
            Picker("深色模式配色", selection: $store.colorSchemeDarkID) {
              ForEach(store.colorSchemes) { scheme in
                Text(scheme.name).tag(scheme.id)
              }
            }
          }
        }

        SettingsGroup("字体") {
          FontFamilyPicker(selection: $store.fontFace)
          SliderRow(title: "候选字号", value: $store.fontPoint, range: 10...36, step: 1, unit: "pt")
          SliderRow(title: "编号字号", value: $store.labelFontPoint, range: 8...30, step: 1, unit: "pt")
          SliderRow(title: "注释字号", value: $store.commentFontPoint, range: 8...30, step: 1, unit: "pt")
        }

        SettingsGroup("布局") {
          Picker("候选排列", selection: $store.useLinearLayout) {
            Text("竖排列表").tag(false)
            Text("横排一行").tag(true)
          }
          .pickerStyle(.segmented)

          Picker("文字方向", selection: $store.useVerticalText) {
            Text("横向").tag(false)
            Text("竖向").tag(true)
          }
          .pickerStyle(.segmented)

          SliderRow(title: "候选窗圆角", value: $store.cornerRadius, range: 0...24, step: 1, unit: "pt")
          SliderRow(title: "高亮圆角", value: $store.hilitedCornerRadius, range: 0...20, step: 1, unit: "pt")
          SliderRow(title: "候选间距", value: $store.lineSpacing, range: 0...24, step: 1, unit: "pt")
          SliderRow(title: "编码区间距", value: $store.preeditSpacing, range: 0...24, step: 1, unit: "pt")
          SliderRow(title: "边框宽度", value: $store.borderWidth, range: 0...20, step: 1, unit: "pt")
          SliderRow(title: "边框高度", value: $store.borderHeight, range: 0...20, step: 1, unit: "pt")
          SliderRow(title: "整体不透明度", value: $store.alpha, range: 0.2...1, step: 0.05, unit: "")

          LabeledContent("候选格式") {
            TextField("", text: $store.candidateFormat)
              .textFieldStyle(.roundedBorder)
              .frame(width: 240)
          }
          Text("可用占位符：[label] 编号 · [candidate] 候选词 · [comment] 注释")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        SettingsGroup("行为") {
          Toggle("内嵌编码：拼音直接显示在输入位置", isOn: $store.inlinePreedit)
          Toggle("内嵌候选：把第一候选也写进输入位置", isOn: $store.inlineCandidate)
          Toggle("毛玻璃背景（需配色带透明度）", isOn: $store.translucency)
          Toggle("显示翻页箭头", isOn: $store.showPaging)
          Toggle("记住候选窗尺寸", isOn: $store.memorizeSize)
          Toggle("横排时高亮互斥", isOn: $store.mutualExclusive)
        }
      }
      .padding(20)
    }
  }
}

// MARK: - 配色色卡

struct ColorSchemeGrid: View {
  @EnvironmentObject private var store: SettingsStore

  private let columns = [GridItem(.adaptive(minimum: 148), spacing: 10)]

  var body: some View {
    LazyVGrid(columns: columns, spacing: 10) {
      ForEach(store.colorSchemes) { scheme in
        SchemeSwatch(scheme: scheme, isSelected: scheme.id == store.colorSchemeID)
          .onTapGesture { store.colorSchemeID = scheme.id }
      }
    }
  }
}

struct SchemeSwatch: View {
  let scheme: RimeColorSchemeInfo
  let isSelected: Bool

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
        if scheme.isCustom {
          Text("自定义")
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
    .help(scheme.author.map { "作者：\($0)" } ?? scheme.id)
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
    LabeledContent("候选字体") {
      Picker("", selection: Binding(
        get: { Self.families.contains(selection) ? selection : "" },
        set: { selection = $0 }
      )) {
        Text("跟随系统").tag("")
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
  let title: String
  @ViewBuilder let content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.caption)
        .fontWeight(.medium)
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
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
