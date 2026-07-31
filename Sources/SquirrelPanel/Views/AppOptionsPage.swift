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
        SettingsGroup("appOptions.title") {
          if store.appOptions.isEmpty {
            EmptyHint(text: String(localized: "appOptions.empty"))
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
              Label("appOptions.addFromApps", systemImage: "plus")
            }
            Menu("appOptions.addCommon") {
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

        SettingsGroup("appOptions.explain.title") {
          ExplainRow(title: String(localized: "appOptions.asciiMode"),
                     detail: String(localized: "appOptions.asciiMode.detail"))
          ExplainRow(title: String(localized: "appOptions.noInline"),
                     detail: String(localized: "appOptions.noInline.detail"))
          ExplainRow(title: String(localized: "appOptions.inline"),
                     detail: String(localized: "appOptions.inline.detail"))
          ExplainRow(title: String(localized: "appOptions.vimMode"),
                     detail: String(localized: "appOptions.vimMode.detail"))
        }
      }
      .padding(20)
    }
  }

  private var headerRow: some View {
    HStack(spacing: 0) {
      Text("appOptions.header.app").frame(maxWidth: .infinity, alignment: .leading)
      Group {
        Text("appOptions.column.ascii").frame(width: 68)
        Text("appOptions.column.noInline").frame(width: 68)
        Text("appOptions.column.inline").frame(width: 68)
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
    panel.prompt = String(localized: "generic.add")
    panel.message = String(localized: "appOptions.panel.message")
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
