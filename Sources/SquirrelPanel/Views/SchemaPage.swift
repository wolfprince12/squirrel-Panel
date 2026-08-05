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
                      description: String(localized: "schema.notFound"), isUserProvided: false)
    }
  }

  private var disabled: [RimeSchema] {
    store.availableSchemas.filter { !store.enabledSchemaIDs.contains($0.id) }
  }

  /// 当前切换快捷键的告警（格式非法 / 被 macOS 系统占用）。无问题返回 nil。
  private var hotkeyWarning: String? {
    let value = store.switcherHotkeys.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    // 支持逗号分隔的多个组合，逐个检查
    for raw in value.split(separator: ",") {
      let combo = raw.trimmingCharacters(in: .whitespaces)
      guard !combo.isEmpty else { continue }
      if HotkeyFormatter.validate(combo) != nil {
        return String(localized: "schema.hotkeys.invalid")
      }
      if HotkeyFormatter.macOSReservedCombo(combo) != nil {
        return String(localized: "schema.hotkeys.reserved")
      }
    }
    return nil
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        SettingsGroup("schema.enabled.title") {
          if enabled.isEmpty {
            EmptyHint(text: String(localized: "schema.enabled.empty"))
          } else {
            Text("schema.enabled.hint")
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

        SettingsGroup("schema.available.title") {
          if disabled.isEmpty {
            EmptyHint(text: store.availableSchemas.isEmpty
                      ? String(localized: "schema.available.empty")
                      : String(localized: "schema.available.allEnabled"))
          } else {
            ForEach(disabled) { schema in
              HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                  Text(schema.name)
                  Text(schema.subtitle + (schema.isUserProvided ? " · " + String(localized: "schema.userProvided") : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("generic.enable") {
                  store.enabledSchemaIDs.append(schema.id)
                }
                .controlSize(.small)
              }
              .padding(.vertical, 2)
              Divider()
            }
          }
          HStack {
            Text("dictionary.scannedFrom")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            Button("schema.available.rescan") { store.reload() }
              .controlSize(.small)
          }
        }

        SettingsGroup("schema.switch.title") {
          LabeledContent("schema.hotkeys") {
            HStack(spacing: 8) {
              HotkeyRecorder(hotkey: $store.switcherHotkeys)
                .frame(width: 200)
              Button("schema.hotkeys.restore") {
                store.switcherHotkeys = ""
              }
              .controlSize(.small)
            }
          }
          if let warning = hotkeyWarning {
            Text(warning)
              .font(.caption)
              .foregroundStyle(.orange)
              .fixedSize(horizontal: false, vertical: true)
          }
          Text("schema.hotkeys.hint")
            .font(.caption)
            .foregroundStyle(.secondary)
          LabeledContent("schema.caption") {
            TextField("〔方案選單〕", text: $store.switcherCaption)
              .textFieldStyle(.roundedBorder)
              .frame(width: 240)
          }
          Divider()
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text("schema.installMore")
              Text("schema.installMore.hint")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("schema.openPlum") {
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
