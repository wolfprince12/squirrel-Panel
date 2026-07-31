//
//  YAMLInspector.swift
//  Squirrel Panel
//
//  展示「点击应用后将写入磁盘」的两份补丁文件内容，
//  让用户在落盘之前看清楚改了什么。
//

import SwiftUI
import AppKit

struct YAMLInspector: View {
  @EnvironmentObject private var store: SettingsStore
  @Environment(\.dismiss) private var dismiss

  private enum Target: String, CaseIterable, Identifiable {
    case squirrel, defaults
    var id: String { rawValue }
    var title: String {
      switch self {
      case .squirrel: return "squirrel.custom.yaml"
      case .defaults: return "default.custom.yaml"
      }
    }
    var note: String {
      switch self {
      case .squirrel: return "外观、候选窗、应用适配"
      case .defaults: return "输入方案、按键行为、每页候选数"
      }
    }
  }

  @State private var target: Target = .squirrel
  @State private var copied = false

  private var preview: (squirrel: String, defaults: String) { store.previewYAML() }

  private var text: String {
    switch target {
    case .squirrel: return preview.squirrel
    case .defaults: return preview.defaults
    }
  }

  private var fileURL: URL {
    RimeEnvironment.userDirectory.appending(path: target.title)
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView([.vertical, .horizontal]) {
        Text(text.isEmpty ? "（这份文件目前没有任何内容）" : text)
          .font(.system(size: 12, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(14)
      }
      .background(Color(nsColor: .textBackgroundColor))
      Divider()
      footer
    }
    .frame(width: 640, height: 520)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("即将写入的配置")
            .font(.headline)
          Text("这是点击「应用并重新部署」后磁盘上的内容，可先核对再落盘。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      Picker("", selection: $target) {
        ForEach(Target.allCases) { item in
          Text(item.title).tag(item)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      Text(target.note + " · " + fileURL.path(percentEncoded: false))
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .padding(14)
  }

  private var footer: some View {
    HStack(spacing: 10) {
      Button("在访达中显示") {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
      }
      .disabled(!FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))

      Button(copied ? "已复制" : "复制内容") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
      }

      Spacer()

      Button("关闭") { dismiss() }
        .keyboardShortcut(.defaultAction)
    }
    .padding(12)
  }
}
