//
//  UserColorSchemeEditor.swift
//  Squirrel Panel
//
//  用户自定义配色方案编辑器。
//
//  左侧列出已保存方案（编辑/删除），右侧为编辑区：
//    · 名称 / 作者 / 颜色空间
//    · 「从现有方案载入」作为配色起点
//    · 全部 *_color 颜色字段：启用开关 + 系统取色器 + 十六进制双向输入
//    · 每条颜色字段都显示「用在哪里」的本地化描述
//    · 实时预览窗
//    · 顶部工具栏：导入 / 导出 / 保存
//
//  注意：本弹出框不提供「应用并重新部署」，该动作只保留在外层 AppearancePage。
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 编辑器的工作模型（@Observable 宏，便于 SwiftUI 双向绑定与属性观察）
@Observable final class SchemeEditorModel {
  var id: String = ""
  var name: String = ""
  var author: String = ""
  var colorSpace: String = "srgb"
  /// 已启用的颜色字段（键 -> RimeColor）；未启用的字段不写入方案，由 Rime 回退默认
  var colors: [String: RimeColor] = [:]

  var isNew: Bool { id.isEmpty }

  func reset() {
    id = ""
    name = ""
    author = ""
    colorSpace = "srgb"
    colors = [:]
  }

  func load(from scheme: UserColorScheme) {
    id = scheme.id
    name = scheme.name
    author = scheme.author
    colorSpace = scheme.colorSpace.isEmpty ? "srgb" : scheme.colorSpace
    colors = [:]
    for (key, value) in scheme.colors where !value.isEmpty {
      if let c = RimeColor(yamlValue: value) { colors[key] = c }
    }
  }

  /// 从某个已有配色方案（内置/开发者/自定义）拷贝其颜色作为编辑起点
  func loadFrom(info: RimeColorSchemeInfo) {
    if id.isEmpty { id = "" }
    colors = [:]
    for (key, value) in info.rawColors { colors[key] = value }
  }

  /// 导出为 UserColorScheme（生成唯一 id）
  func toScheme(existingIDs: Set<String>) -> UserColorScheme {
    let baseID: String
    if id.isEmpty {
      baseID = UserColorScheme.makeID(from: name.isEmpty ? "my-scheme" : name)
    } else {
      baseID = id
    }
    var uniqueID = baseID
    var suffix = 2
    while existingIDs.contains(uniqueID) && uniqueID != id {
      uniqueID = "\(baseID)-\(suffix)"
      suffix += 1
    }
    var colorMap: [String: String] = [:]
    for (key, value) in colors {
      colorMap[key] = value.literal
    }
    return UserColorScheme(id: uniqueID, name: name.isEmpty ? "未命名方案" : name,
                           author: author, colorSpace: colorSpace, colors: colorMap)
  }

  /// 当前编辑结果的预览信息
  func previewInfo(id fallbackID: String) -> RimeColorSchemeInfo {
    RimeColorSchemeInfo(
      id: fallbackID,
      name: name.isEmpty ? "预览" : name,
      author: author.isEmpty ? nil : author,
      colorSpace: RimeColorSpace.from(name: colorSpace),
      rawColors: colors,
      isCustom: true
    )
  }
}

struct UserColorSchemeEditor: View {
  @Environment(SettingsStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var model = SchemeEditorModel()
  @State private var schemes: [UserColorScheme] = UserColorSchemes.all
  @State private var selectedID: String? = UserColorSchemes.all.first?.id
  @State private var statusMessage: String?
  @State private var importErrorMessage: String?

  private var selectedScheme: UserColorScheme? {
    guard let id = selectedID else { return nil }
    return schemes.first { $0.id == id }
  }

  var body: some View {
    HSplitView {
      // 左侧：已保存方案列表
      listPane
        .frame(minWidth: 150, idealWidth: 170, maxWidth: 220)
      // 右侧：编辑区
      editorPane
        .frame(minWidth: 520)
    }
    .frame(width: 880, height: 600)
    .alert("scheme.import.failed.title", isPresented: Binding(
      get: { importErrorMessage != nil },
      set: { if !$0 { importErrorMessage = nil } })) {
      Button("common.ok", role: .cancel) {}
    } message: {
      Text(importErrorMessage ?? "")
    }
  }

  // MARK: - 列表

  private var listPane: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("scheme.list.title")
          .font(.headline)
        Spacer()
        Button(action: newScheme) { Image(systemName: "plus") }
          .help("scheme.list.new")
      }
      .padding(12)

      Divider()

      List(selection: $selectedID) {
        ForEach(schemes) { scheme in
          HStack(spacing: 10) {
            schemePreviewStripe(scheme)
              .frame(width: 5, height: 32)
              .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
              Text(scheme.name.isEmpty ? scheme.id : scheme.name)
                .lineLimit(1)
              if !scheme.author.isEmpty {
                Text(scheme.author)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
            }

            Spacer()

            Button(action: { deleteScheme(scheme) }) {
              Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("scheme.list.delete")
          }
          .tag(scheme.id)
          .padding(.vertical, 2)
        }
      }
      .listStyle(.inset)
      .onChange(of: selectedID) { _, newID in
        if let s = schemes.first(where: { $0.id == newID }) {
          model.load(from: s)
        }
      }
    }
  }

  /// 左侧列表中每条方案的小色条预览
  private func schemePreviewStripe(_ scheme: UserColorScheme) -> some View {
    let info = UserColorSchemes.info(for: scheme)
    return VStack(spacing: 0) {
      Rectangle().fill(info.color(info.background))
      Rectangle().fill(info.color(info.highlightedCandidateBackground ?? info.background))
      Rectangle().fill(info.color(info.candidateBackground ?? info.background))
    }
  }

  // MARK: - 编辑区

  private var editorPane: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        // 顶部工具栏
        topBar
        // 基本信息
        basicInfo
        // 实时预览
        previewCard
        // 颜色字段
        colorSection
      }
      .padding(12)
    }
  }

  private var topBar: some View {
    HStack(spacing: 12) {
      Button("common.done") { dismiss() }
        .controlSize(.small)

      if let message = statusMessage {
        Text(LocalizedStringKey(message))
          .font(.caption2)
          .foregroundStyle(.secondary)
          .transition(.opacity)
      }

      Spacer()

      HStack(spacing: 8) {
        Button(action: { importScheme() }) {
          Label("scheme.action.import", systemImage: "square.and.arrow.down")
        }
        .labelStyle(.iconOnly)
        .help("scheme.action.import")

        Button(action: { exportScheme() }) {
          Label("scheme.action.export", systemImage: "square.and.arrow.up")
        }
        .labelStyle(.iconOnly)
        .help("scheme.action.export")
        .disabled(model.name.isEmpty && model.colors.isEmpty)

        Button("scheme.action.use") { useSelectedScheme() }
          .disabled(selectedID == nil)
          .buttonStyle(.bordered)

        Button("scheme.action.save") { saveScheme() }
          .keyboardShortcut("s", modifiers: .command)
          .buttonStyle(.borderedProminent)
      }
      .controlSize(.small)
    }
  }

  private var basicInfo: some View {
    HStack(alignment: .top, spacing: 16) {
      VStack(alignment: .leading, spacing: 2) {
        Text(LocalizedStringKey("scheme.field.name"))
          .font(.caption)
          .foregroundStyle(.secondary)
        TextField("", text: $model.name)
          .textFieldStyle(.roundedBorder)
          .frame(width: 170)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(LocalizedStringKey("scheme.field.author"))
          .font(.caption)
          .foregroundStyle(.secondary)
        TextField("", text: $model.author)
          .textFieldStyle(.roundedBorder)
          .frame(width: 150)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(LocalizedStringKey("scheme.field.colorSpace"))
          .font(.caption)
          .foregroundStyle(.secondary)
        Picker("", selection: $model.colorSpace) {
          Text("scheme.colorSpace.srgb").tag("srgb")
          Text("scheme.colorSpace.p3").tag("display_p3")
        }
        .pickerStyle(.segmented)
        .frame(width: 170)
      }
    }
  }

  private var previewCard: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("scheme.preview.title")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Button("scheme.loadFrom.title") { loadFromMenu() }
          .controlSize(.small)
          .help("scheme.loadFrom.hint")
      }
      CandidatePanel(scheme: model.previewInfo(id: selectedID ?? "preview"), height: 130)
        .frame(height: 130)
    }
  }

  private var colorSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text("scheme.section.colors")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Text(String(format: String(localized: "scheme.section.colors.count"), model.colors.count))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Text("scheme.section.colors.hint")
        .font(.caption2)
        .foregroundStyle(.secondary)
      // 双列紧凑布局：把 19 个颜色字段拆成左右两栏，显著降低纵向占用
      let fields = UserColorSchemes.colorFields
      let mid = (fields.count + 1) / 2
      HStack(alignment: .top, spacing: 18) {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(fields.prefix(mid), id: \.key) { field in colorRow(field) }
        }
        VStack(alignment: .leading, spacing: 4) {
          ForEach(fields.suffix(from: mid), id: \.key) { field in colorRow(field) }
        }
      }
    }
  }

  private func colorRow(_ field: (key: String, titleKey: String, descriptionKey: String)) -> some View {
    ColorFieldRow(
      field: field,
      compact: true,
      color: Binding(
        get: { model.colors[field.key] },
        set: { model.colors[field.key] = $0 }
      )
    )
  }

  // MARK: - 行为

  private func newScheme() {
    model.reset()
    selectedID = nil
  }

  private func saveScheme() {
    let scheme = model.toScheme(existingIDs: Set(schemes.map { $0.id }))
    UserColorSchemes.save(scheme)
    schemes = UserColorSchemes.all
    selectedID = scheme.id
    statusMessage = "scheme.status.saved"
  }

  /// 将当前选中的自定义方案「确认」为外观页自定义模块所展示的那一套。
  /// 这是纯登记动作：仅写入独立的 confirmedID，与全局 colorSchemeID 完全无关，
  /// 不会让鼠须管改用此方案，也不会触发任何部署。
  /// 若要让鼠须管实际渲染该配色，需在外观页自定义模块或主色卡网格中选中它并点「应用并重新部署」。
  private func useSelectedScheme() {
    // 确保当前方案已落盘（新建未保存时先保存，拿到稳定 id）
    let scheme: UserColorScheme
    if let id = selectedID, let existing = schemes.first(where: { $0.id == id }) {
      scheme = existing
    } else {
      scheme = model.toScheme(existingIDs: Set(schemes.map { $0.id }))
      UserColorSchemes.save(scheme)
      schemes = UserColorSchemes.all
      selectedID = scheme.id
    }
    // 仅登记为「确认使用的自定义方案」，供外观页模块展示
    UserColorSchemes.confirm(scheme.id)
    statusMessage = "scheme.status.confirmed"
  }

  private func deleteScheme(_ scheme: UserColorScheme) {
    // 若删除的正是当前确认使用方案，清除独立标记
    if UserColorSchemes.confirmedID == scheme.id {
      UserColorSchemes.confirmedID = nil
    }
    UserColorSchemes.remove(id: scheme.id)
    schemes = UserColorSchemes.all
    if selectedID == scheme.id { selectedID = schemes.first?.id; if let f = schemes.first { model.load(from: f) } }
    // 同步清理 squirrel.custom.yaml 中的注入
    store.apply()
  }

  private func loadFromMenu() {
    // 以当前生效配色作为修改起点（内置/开发者/自定义方案都可先在外部应用再进入编辑器微调）
    model.loadFrom(info: store.currentScheme)
    statusMessage = "scheme.status.loadedCurrent"
  }

  private func importScheme() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.yaml, .plainText]
    panel.allowsMultipleSelection = false
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    let response = panel.runModal()
    guard response == .OK else { return } // 用户取消或按 Esc，静默处理
    guard let url = panel.url,
          let text = try? String(contentsOf: url, encoding: .utf8),
          let scheme = UserColorSchemes.parseImportedYAML(text) else {
      importErrorMessage = String(localized: "scheme.import.failed")
      return
    }
    UserColorSchemes.save(scheme)
    schemes = UserColorSchemes.all
    selectedID = scheme.id
    model.load(from: scheme)
    statusMessage = "scheme.status.imported"
  }

  /// 把当前编辑的方案导出为独立 .yaml 片段（含 preset_color_schemes 定义，可直接被 Rime 复用或再导入）
  private func exportScheme() {
    let scheme = model.toScheme(existingIDs: Set(schemes.map { $0.id }))
    var lines: [String] = []
    lines.append("# 鼠须管控制面板 · 用户自定义配色方案")
    lines.append("# 名称：\(scheme.name)")
    if !scheme.author.isEmpty { lines.append("# 作者：\(scheme.author)") }
    lines.append("preset_color_schemes:")
    lines.append("  \(scheme.id):")
    lines.append("    name: \(scheme.name)")
    lines.append("    author: \(scheme.author)")
    if scheme.colorSpace.lowercased() == "display_p3" {
      lines.append("    color_space: display_p3")
    }
    for key in UserColorSchemes.colorFields.map({ $0.key }) {
      if let value = scheme.colors[key], !value.isEmpty {
        lines.append("    \(key): \"\(value)\"")
      }
    }
    let yaml = lines.joined(separator: "\n") + "\n"

    let save = NSSavePanel()
    save.allowedContentTypes = [.yaml]
    save.nameFieldStringValue = "\(scheme.id).yaml"
    save.canCreateDirectories = true
    guard save.runModal() == .OK, let url = save.url else { return }
    try? yaml.write(to: url, atomically: true, encoding: .utf8)
  }
}

// MARK: - 单个颜色字段行

struct ColorFieldRow: View {
  let field: (key: String, titleKey: String, descriptionKey: String)
  var compact: Bool = false
  @Binding var color: RimeColor?

  var body: some View {
    HStack(spacing: 8) {
      Toggle("", isOn: Binding(
        get: { color != nil },
        set: { on in
          if on { color = color ?? RimeColor(red: 0, green: 0, blue: 0, alpha: 1) }
          else { color = nil }
        }
      ))
      .toggleStyle(.checkbox)
      .labelsHidden()
      .frame(width: 18)

      colorSwatch
        .frame(width: 22, height: 22)

      VStack(alignment: .leading, spacing: 1) {
        Text(LocalizedStringKey(field.titleKey))
          .font(.caption)
          .fontWeight(.medium)
          .lineLimit(1)
        Text(LocalizedStringKey(field.descriptionKey))
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if let c = color {
        HStack(spacing: 6) {
          TextField("0xBBGGRR", text: Binding(
            get: { color?.literal ?? "" },
            set: { hex in
              let trimmed = hex.trimmingCharacters(in: .whitespaces)
              if trimmed.isEmpty {
                color = nil
              } else if let parsed = RimeColor(yamlValue: trimmed) {
                color = parsed
              }
            }
          ))
          .textFieldStyle(.roundedBorder)
          .frame(width: 76, height: 20)
          .font(.caption.monospacedDigit())
          .controlSize(.small)

          ColorPicker("", selection: Binding(
            get: { c.swiftUIColor(in: .sRGB) },
            set: { color = RimeColor($0, in: .sRGB) }
          ))
          .labelsHidden()
          .frame(width: 22, height: 20)
        }
      } else {
        Text("scheme.field.default")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .frame(height: compact ? 28 : 32)
    .padding(.horizontal, 6)
    .background(color != nil ? Color.accentColor.opacity(0.04) : Color.clear)
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }

  /// 颜色开关：启用时显示当前颜色；禁用时显示「不使用」占位
  private var colorSwatch: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 5, style: .continuous)
        .fill(color.map { $0.swiftUIColor(in: .sRGB) } ?? Color.primary.opacity(0.06))
      if color == nil {
        Image(systemName: "minus")
          .font(.system(size: 8, weight: .semibold))
          .foregroundStyle(.secondary.opacity(0.6))
      }
    }
    .overlay(
      RoundedRectangle(cornerRadius: 5, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
    )
  }
}
