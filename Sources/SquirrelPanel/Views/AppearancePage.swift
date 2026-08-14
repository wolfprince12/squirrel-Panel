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

        // 开发者（大狼）专属签名配色：独立模块，不混入总色卡网格
        SettingsGroup("appearance.scheme.developer.title") {
          Text("appearance.scheme.developer.hint")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 2)
          DeveloperSchemeGrid()
        }

        SettingsGroup("appearance.scheme.title") {
          ColorSchemeGrid()
          Toggle("appearance.scheme.followSystem", isOn: $store.followSystemAppearance)
            .padding(.top, 4)
          if store.followSystemAppearance {
            Picker("appearance.scheme.dark", selection: $store.colorSchemeDarkID) {
              ForEach(store.colorSchemes.filter { !DeveloperColorSchemes.ids.contains($0.id) }) { scheme in
                Text(scheme.name).tag(scheme.id)
              }
              Divider()
              ForEach(DeveloperColorSchemes.all) { scheme in
                let info = DeveloperColorSchemes.info(for: scheme)
                Text(info.name).tag(info.id)
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
  }
}

// MARK: - 配色色卡

struct ColorSchemeGrid: View {
  @EnvironmentObject private var store: SettingsStore

  private let columns = [GridItem(.adaptive(minimum: 148), spacing: 10)]

  var body: some View {
    LazyVGrid(columns: columns, spacing: 10) {
      ForEach(store.colorSchemes.filter { !DeveloperColorSchemes.ids.contains($0.id) }) { scheme in
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
    .help(scheme.author.map { String(format: String(localized: "appearance.scheme.author"), $0) } ?? scheme.id)
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
