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
    guard let modified else { return "从未使用" }
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
        SettingsGroup("用户词库") {
          if dictionaries.isEmpty {
            EmptyHint(text: "尚未生成任何用户词库。正常使用鼠须管输入一段时间后，这里会列出各方案的学习记录。")
          } else {
            ForEach(dictionaries) { dict in
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(dict.name)
                  Text("\(dict.sizeText) · 最近更新 \(dict.modifiedText)")
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
            Text("词库位于 ~/Library/Rime")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            Button("在访达中打开") {
              SquirrelBridge.reveal(RimeEnvironment.userDirectory)
            }
            .controlSize(.small)
          }
        }

        SettingsGroup("同步") {
          LabeledContent("安装 ID") {
            TextField("这台设备的标识", text: $installationID)
              .textFieldStyle(.roundedBorder)
              .frame(width: 220)
          }
          Text("多台设备之间必须各不相同，否则同步会互相覆盖。")
            .font(.caption)
            .foregroundStyle(.secondary)

          LabeledContent("同步目录") {
            HStack(spacing: 6) {
              TextField("留空则使用 ~/Library/Rime/sync", text: $syncDirectory)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
              Button("选择…") { chooseSyncDirectory() }
                .controlSize(.small)
            }
          }
          Text("可以指向 iCloud 云盘或其他同步盘中的文件夹，实现多机同步。")
            .font(.caption)
            .foregroundStyle(.secondary)

          Divider()
          HStack(spacing: 10) {
            Button("保存同步设置") { saveInstallation() }
            Button("立即同步用户数据") {
              do {
                try SquirrelBridge.sync(environment: store.environment)
                message = "已发起同步"
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

        SettingsGroup("维护") {
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text("重新编译全部方案")
              Text("方案文件改动后需要重新部署才会生效")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("重新部署") {
              do {
                try SquirrelBridge.deploy(environment: store.environment)
                message = "已发起部署"
              } catch {
                message = error.localizedDescription
              }
            }
            .disabled(!store.environment.isInstalled)
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
    panel.prompt = "选择"
    panel.message = "选择用于同步的文件夹"
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
      message = "同步设置已保存"
    } catch {
      message = error.localizedDescription
    }
  }
}
