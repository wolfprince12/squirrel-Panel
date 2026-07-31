//
//  AboutPage.swift
//  Squirrel Panel
//

import SwiftUI

struct AboutPage: View {
  @EnvironmentObject private var store: SettingsStore
  @Binding var showingResetAlert: Bool

  private var panelVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        SettingsGroup("运行状态") {
          InfoRow(label: "控制面板", value: "v\(panelVersion)")
          Divider()
          InfoRow(label: "鼠须管",
                  value: store.environment.isInstalled
                    ? "已安装 v\(store.environment.version ?? "未知")"
                    : "未检测到")
          Divider()
          InfoRow(label: "输入法进程", value: store.environment.isRunning ? "运行中" : "未运行")
          Divider()
          InfoRow(label: "用户目录",
                  value: store.environment.isUserDirectoryReady ? "已就绪" : "尚未创建")
        }

        SettingsGroup("路径") {
          PathRow(title: "用户配置目录", url: RimeEnvironment.userDirectory)
          Divider()
          if let shared = store.environment.sharedSupportURL {
            PathRow(title: "内置数据目录", url: shared)
            Divider()
          }
          PathRow(title: "日志目录", url: RimeEnvironment.logDirectory)
        }

        SettingsGroup("维护") {
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text("重新读取配置")
              Text("如果你在外部编辑过 YAML，用它刷新界面")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("重新读取") { store.reload() }
          }
          Divider()
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text("恢复默认设置")
              Text("移除控制面板写入的全部配置项，保留你手写的条目")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("恢复默认", role: .destructive) { showingResetAlert = true }
              .disabled(!store.canWrite)
          }
        }

        SettingsGroup("关于") {
          Text("鼠须管控制面板是一个独立的第三方工具，用于图形化配置 Rime 输入法引擎的 macOS 前端「鼠须管」(Squirrel)。")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
          Text("本项目不隶属于 RIME 官方，也不会修改鼠须管本体。所有改动都以标准的 Rime 补丁文件形式写入用户目录，随时可以手动编辑或删除。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Divider()
          HStack(spacing: 10) {
            Link("项目主页", destination: URL(string: "https://github.com/wolfprince12/squirrel-Panel")!)
            Link("反馈问题", destination: URL(string: "https://github.com/wolfprince12/squirrel-Panel/issues")!)
            Link("RIME 官网", destination: URL(string: "https://rime.im")!)
            Link("鼠须管源码", destination: URL(string: "https://github.com/rime/squirrel")!)
          }
          .font(.callout)
          Text("以 GPL-3.0 协议开源。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(20)
    }
  }
}

private struct InfoRow: View {
  let label: String
  let value: String

  var body: some View {
    HStack {
      Text(label)
      Spacer()
      Text(value).foregroundStyle(.secondary)
    }
  }
}

private struct PathRow: View {
  let title: String
  let url: URL

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(url.path(percentEncoded: false))
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer()
      Button("打开") { SquirrelBridge.reveal(url) }
        .controlSize(.small)
    }
  }
}
