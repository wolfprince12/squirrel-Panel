//
//  SchemaPage.swift
//  Squirrel Panel
//

import SwiftUI

struct SchemaPage: View {
  @EnvironmentObject private var store: SettingsStore

  private var enabled: [RimeSchema] {
    store.enabledSchemaIDs.compactMap { id in
      store.availableSchemas.first { $0.id == id }
        ?? RimeSchema(id: id, name: id, version: nil, author: nil,
                      description: "方案文件未找到，可能尚未安装", isUserProvided: false)
    }
  }

  private var disabled: [RimeSchema] {
    store.availableSchemas.filter { !store.enabledSchemaIDs.contains($0.id) }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        SettingsGroup("已启用的方案") {
          if enabled.isEmpty {
            EmptyHint(text: "还没有启用任何方案。从下方列表勾选，或先在鼠须管中完成一次部署。")
          } else {
            Text("按住拖动可调整顺序，第一项为默认方案")
              .font(.caption)
              .foregroundStyle(.secondary)
            List {
              ForEach(enabled) { schema in
                HStack(spacing: 10) {
                  Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(schema.name)
                    Text(schema.subtitle)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  Spacer()
                  Button {
                    store.enabledSchemaIDs.removeAll { $0 == schema.id }
                  } label: {
                    Image(systemName: "minus.circle")
                  }
                  .buttonStyle(.borderless)
                  .foregroundStyle(.red)
                }
                .padding(.vertical, 2)
              }
              .onMove { indices, destination in
                store.enabledSchemaIDs.move(fromOffsets: indices, toOffset: destination)
              }
            }
            .listStyle(.plain)
            .frame(height: CGFloat(min(enabled.count, 8)) * 42 + 8)
            .scrollContentBackground(.hidden)
          }
        }

        SettingsGroup("可用方案") {
          if disabled.isEmpty {
            EmptyHint(text: store.availableSchemas.isEmpty
                      ? "未扫描到任何 *.schema.yaml。请确认鼠须管已安装并至少部署过一次。"
                      : "本机所有方案都已启用。")
          } else {
            ForEach(disabled) { schema in
              HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                  Text(schema.name)
                  Text(schema.subtitle + (schema.isUserProvided ? " · 用户目录" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("启用") {
                  store.enabledSchemaIDs.append(schema.id)
                }
                .controlSize(.small)
              }
              .padding(.vertical, 2)
              Divider()
            }
          }
          HStack {
            Text("扫描自 ~/Library/Rime 与 Squirrel.app 的 SharedSupport")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            Button("重新扫描") { store.reload() }
              .controlSize(.small)
          }
        }

        SettingsGroup("方案切换") {
          LabeledContent("切换快捷键") {
            TextField("Control+grave, F4", text: $store.switcherHotkeys)
              .textFieldStyle(.roundedBorder)
              .frame(width: 240)
          }
          Text("多个快捷键用英文逗号分隔。留空则沿用鼠须管默认值。")
            .font(.caption)
            .foregroundStyle(.secondary)
          LabeledContent("切换菜单标题") {
            TextField("〔方案選單〕", text: $store.switcherCaption)
              .textFieldStyle(.roundedBorder)
              .frame(width: 240)
          }
          Divider()
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text("安装更多方案")
              Text("通过东风破 plum 从官方仓库获取")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("打开方案库") {
              NSWorkspace.shared.open(URL(string: "https://github.com/rime/plum")!)
            }
            .controlSize(.small)
          }
        }
      }
      .padding(20)
    }
  }
}

struct EmptyHint: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 6)
  }
}
