//
//  AppOptionsPage.swift
//  Squirrel Panel
//
//  按应用设定输入法默认状态。对应 squirrel.custom.yaml 的 app_options 段。
//  手写这段最麻烦的是要自己去查 Bundle ID，这里直接从 .app 里读。
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AppOptionsPage: View {
  @EnvironmentObject private var store: SettingsStore

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        SettingsGroup("按应用设定") {
          if store.appOptions.isEmpty {
            EmptyHint(text: "还没有任何应用规则。常见用法：在终端、代码编辑器里默认切换到英文。")
          } else {
            headerRow
            Divider()
            ForEach($store.appOptions) { $entry in
              AppOptionRow(entry: $entry) {
                store.appOptions.removeAll { $0.bundleID == entry.bundleID }
              }
              Divider()
            }
          }

          HStack(spacing: 10) {
            Button {
              chooseApplication()
            } label: {
              Label("从「应用程序」添加", systemImage: "plus")
            }
            Menu("添加常用应用") {
              ForEach(Self.presets, id: \.bundleID) { preset in
                Button(preset.name) { add(bundleID: preset.bundleID, defaultASCII: true) }
                  .disabled(store.appOptions.contains { $0.bundleID == preset.bundleID })
              }
            }
            .frame(width: 160)
            Spacer()
          }
          .padding(.top, 4)
        }

        SettingsGroup("选项说明") {
          ExplainRow(title: "默认英文",
                     detail: "切换到该应用时自动进入英文（ASCII）模式，对应 ascii_mode。")
          ExplainRow(title: "禁用内嵌",
                     detail: "该应用中不把拼音写进输入位置，改用候选窗顶部显示，对应 no_inline。适合内嵌显示异常的应用。")
          ExplainRow(title: "强制内嵌",
                     detail: "该应用中强制使用内嵌编码，对应 inline。")
          ExplainRow(title: "Vim 模式",
                     detail: "该应用失去输入焦点时自动切回英文，对应 vim_mode。适合 Vim、Emacs 一类的模式化编辑器。")
        }
      }
      .padding(20)
    }
  }

  private var headerRow: some View {
    HStack(spacing: 0) {
      Text("应用").frame(maxWidth: .infinity, alignment: .leading)
      Group {
        Text("默认英文").frame(width: 68)
        Text("禁用内嵌").frame(width: 68)
        Text("强制内嵌").frame(width: 68)
        Text("Vim").frame(width: 44)
        Color.clear.frame(width: 28)
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  // MARK: - 添加

  private static let presets: [(name: String, bundleID: String)] = [
    ("终端 Terminal", "com.apple.Terminal"),
    ("iTerm2", "com.googlecode.iterm2"),
    ("Visual Studio Code", "com.microsoft.VSCode"),
    ("Xcode", "com.apple.dt.Xcode"),
    ("Spotlight", "com.apple.Spotlight"),
    ("Warp", "dev.warp.Warp-Stable"),
    ("Final Cut Pro", "com.apple.FinalCut")
  ]

  private func chooseApplication() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    panel.allowsMultipleSelection = true
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.prompt = "添加"
    panel.message = "选择要单独设定输入状态的应用"
    guard panel.runModal() == .OK else { return }
    for url in panel.urls {
      guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
      add(bundleID: id, defaultASCII: false)
    }
  }

  private func add(bundleID: String, defaultASCII: Bool) {
    guard !store.appOptions.contains(where: { $0.bundleID == bundleID }) else { return }
    var entry = AppOptionEntry(bundleID: bundleID,
                               displayName: SettingsStore.displayName(for: bundleID))
    entry.asciiMode = defaultASCII
    store.appOptions.append(entry)
    store.appOptions.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
  }
}

// MARK: - 单行

private struct AppOptionRow: View {
  @Binding var entry: AppOptionEntry
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      HStack(spacing: 8) {
        AppIcon(bundleID: entry.bundleID)
        VStack(alignment: .leading, spacing: 1) {
          Text(entry.displayName)
          Text(entry.bundleID)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Toggle("", isOn: $entry.asciiMode).labelsHidden().frame(width: 68)
      Toggle("", isOn: $entry.noInline).labelsHidden().frame(width: 68)
      Toggle("", isOn: $entry.inline).labelsHidden().frame(width: 68)
      Toggle("", isOn: $entry.vimMode).labelsHidden().frame(width: 44)

      Button(action: onDelete) {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.red)
      .frame(width: 28)
    }
    .padding(.vertical, 3)
  }
}

private struct AppIcon: View {
  let bundleID: String

  var body: some View {
    Group {
      if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
          .resizable()
      } else {
        Image(systemName: "questionmark.app.dashed")
          .resizable()
          .foregroundStyle(.tertiary)
      }
    }
    .frame(width: 22, height: 22)
  }
}

private struct ExplainRow: View {
  let title: String
  let detail: String

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Text(title)
        .font(.callout)
        .frame(width: 76, alignment: .leading)
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
