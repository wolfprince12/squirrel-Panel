//
//  DictionaryPage.swift
//  Squirrel Panel
//
//  用户词库与同步。鼠须管的同步由 librime 完成，这里负责配置 installation.yaml
//  并通过官方通道触发同步。
//

import SwiftUI
import Yams

struct UserDictInfo: Identifiable {
  var id: String { name }
  let name: String
  let sizeBytes: Int64
  let modified: Date?

  var sizeText: String {
    ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
  }

  var modifiedText: String {
    guard let modified else { return String(localized: "dictionary.neverUsed") }
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    return formatter.localizedString(for: modified, relativeTo: Date())
  }
}

struct DictionaryPage: View {
  @EnvironmentObject private var store: SettingsStore
  @State private var dictionaries: [UserDictInfo] = []
  @State private var installationID = ""
  @State private var syncDirectory = ""
  @State private var message = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        SettingsGroup("dictionary.title") {
          if dictionaries.isEmpty {
            EmptyHint(text: String(localized: "dictionary.empty"))
          } else {
            ForEach(dictionaries) { dict in
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(dict.name)
                  Text("\(dict.sizeText) · " + String(format: String(localized: "dictionary.lastUpdated"), dict.modifiedText))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
              }
              .padding(.vertical, 2)
              Divider()
            }
          }
          HStack {
            Text("dictionary.location")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            Button("dictionary.openInFinder") {
              SquirrelBridge.reveal(RimeEnvironment.userDirectory)
            }
            .controlSize(.small)
          }
        }

        SettingsGroup("dictionary.sync.title") {
          LabeledContent("dictionary.sync.id") {
            TextField("dictionary.sync.idPlaceholder", text: $installationID)
              .textFieldStyle(.roundedBorder)
              .frame(width: 220)
          }
          Text("dictionary.sync.id.hint")
            .font(.caption)
            .foregroundStyle(.secondary)

          LabeledContent("dictionary.sync.dir") {
            HStack(spacing: 6) {
              TextField("dictionary.sync.dirPlaceholder", text: $syncDirectory)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
              Button("generic.choose") { chooseSyncDirectory() }
                .controlSize(.small)
            }
          }
          Text("dictionary.sync.dir.hint")
            .font(.caption)
            .foregroundStyle(.secondary)

          Divider()
          HStack(spacing: 10) {
            Button("dictionary.save") { saveInstallation() }
            Button("dictionary.syncNowData") {
              do {
                try SquirrelBridge.sync(environment: store.environment)
                message = String(localized: "dictionary.message.syncStarted")
              } catch {
                message = error.localizedDescription
              }
            }
            .disabled(!store.environment.isInstalled)
            Spacer()
            if !message.isEmpty {
              Text(message).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }
      .padding(20)
    }
    .onAppear(perform: load)
  }

  // MARK: - 载入与保存

  private func load() {
    dictionaries = Self.scanDictionaries()
    let url = RimeEnvironment.userDirectory.appending(path: "installation.yaml")
    guard let text = try? String(contentsOf: url, encoding: .utf8),
          let object = try? Yams.load(yaml: text) as? [String: Any] else { return }
    installationID = (object["installation_id"] as? String) ?? ""
    syncDirectory = (object["sync_dir"] as? String) ?? ""
  }

  private static func scanDictionaries() -> [UserDictInfo] {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(
      at: RimeEnvironment.userDirectory,
      includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
      options: [.skipsHiddenFiles]) else { return [] }

    return items.filter { $0.pathExtension == "userdb" || $0.lastPathComponent.hasSuffix(".userdb") }
      .compactMap { url in
        let size = directorySize(url)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return UserDictInfo(
          name: url.lastPathComponent.replacingOccurrences(of: ".userdb", with: ""),
          sizeBytes: size,
          modified: modified)
      }
      .sorted { $0.name < $1.name }
  }

  private static func directorySize(_ url: URL) -> Int64 {
    let fm = FileManager.default
    var total: Int64 = 0
    if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
      for case let file as URL in enumerator {
        total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
      }
    }
    if total == 0 {
      total = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
    return total
  }

  private func chooseSyncDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = String(localized: "generic.choose")
    panel.message = String(localized: "dictionary.syncDir.message")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    syncDirectory = url.path(percentEncoded: false)
  }

  /// installation.yaml 由 librime 维护，这里只改动我们关心的两个字段
  private func saveInstallation() {
    let url = RimeEnvironment.userDirectory.appending(path: "installation.yaml")
    var object: [String: Any] = [:]
    if let text = try? String(contentsOf: url, encoding: .utf8),
       let existing = try? Yams.load(yaml: text) as? [String: Any] {
      object = existing
    }
    if installationID.isEmpty {
      object.removeValue(forKey: "installation_id")
    } else {
      object["installation_id"] = installationID
    }
    if syncDirectory.isEmpty {
      object.removeValue(forKey: "sync_dir")
    } else {
      object["sync_dir"] = syncDirectory
    }
    do {
      try FileManager.default.createDirectory(at: RimeEnvironment.userDirectory,
                                              withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
        let backup = url.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: url, to: backup)
      }
      let body = try Yams.dump(object: object, width: -1, allowUnicode: true, sortKeys: true)
      try body.write(to: url, atomically: true, encoding: .utf8)
      message = String(localized: "dictionary.message.saved")
    } catch {
      message = error.localizedDescription
    }
  }
}
