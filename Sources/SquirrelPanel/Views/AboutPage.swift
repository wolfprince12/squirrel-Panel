//
//  AboutPage.swift
//  Squirrel Panel
//

import SwiftUI
import AppKit

struct AboutPage: View {
  @EnvironmentObject private var store: SettingsStore
  @Binding var showingResetAlert: Bool

  private var panelVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? String(localized: "generic.dev")
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        headerCard
        developerCard
        promotionSection
        statusCard
        pathsCard
        maintenanceCard
        projectCard
      }
      .padding(20)
    }
  }

  // MARK: - 顶部 Logo 与版本

  private var headerCard: some View {
    HStack(spacing: 20) {
      if let image = logoImage {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 88, height: 88)
          .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
          .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text("app.name")
          .font(.title2.bold())
        Text("v\(panelVersion)")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(20)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private var logoImage: NSImage? {
    guard let url = Bundle.main.url(forResource: "AppLogo", withExtension: "png") else { return nil }
    return NSImage(contentsOf: url)
  }

  // MARK: - 开发者信息

  private var developerCard: some View {
    SettingsGroup("about.header.developer") {
      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text("about.developer.name")
            .font(.headline)
          Text("about.developer.title")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Text("about.developer.company")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("about.developer.bio")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
        }
        Spacer()
      }
    }
  }

  // MARK: - 推广区

  private var promotionSection: some View {
    SettingsGroup("about.header.moreWorks") {
      VStack(spacing: 12) {
        PromotionRow(
          icon: "message.fill",
          iconColor: .green,
          title: "promo.yaozhi.title",
          subtitle: "promo.yaozhi.subtitle",
          description: "promo.yaozhi.description",
          actionTitle: "promo.yaozhi.action",
          action: { openWeChatSearch(account: "爻知云AI") }
        )
        Divider()
        PromotionRow(
          icon: "doc.text.fill",
          iconColor: .indigo,
          title: "promo.dealv.title",
          subtitle: "promo.dealv.subtitle",
          description: "promo.dealv.description",
          actionTitle: "promo.dealv.action",
          action: { openURL("https://dealv.io") }
        )
      }
    }
  }

  // MARK: - 运行状态

  private var statusCard: some View {
    SettingsGroup("about.header.status") {
      InfoRow(label: String(localized: "about.panel.version"), value: "v\(panelVersion)")
      Divider()
      InfoRow(label: String(localized: "about.squirrel.installed"),
              value: store.environment.isInstalled
                ? String(format: String(localized: "about.squirrel.version"), store.environment.version ?? String(localized: "generic.unknown"))
                : String(localized: "about.squirrel.notInstalled"))
      Divider()
      InfoRow(label: String(localized: "about.squirrel.process"),
              value: store.environment.isRunning
                ? String(localized: "about.squirrel.running")
                : String(localized: "about.squirrel.notRunning"))
      Divider()
      InfoRow(label: String(localized: "about.userDir"),
              value: store.environment.isUserDirectoryReady
                ? String(localized: "about.userDir.ready")
                : String(localized: "about.userDir.notReady"))
    }
  }

  // MARK: - 路径

  private var pathsCard: some View {
    SettingsGroup("about.header.paths") {
      PathRow(title: String(localized: "dictionary.location"), url: RimeEnvironment.userDirectory)
      Divider()
      if let shared = store.environment.sharedSupportURL {
        PathRow(title: String(localized: "dictionary.scannedFrom"), url: shared)
        Divider()
      }
      PathRow(title: String(localized: "about.panel.version"), url: RimeEnvironment.logDirectory)
    }
  }

  // MARK: - 维护

  private var maintenanceCard: some View {
    SettingsGroup("about.header.maintenance") {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("about.reload.title")
          Text("about.reload.subtitle")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("about.reload.button") { store.reload() }
      }
      Divider()
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("about.reset.title")
          Text("about.reset.subtitle")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("about.reset.button", role: .destructive) { showingResetAlert = true }
          .disabled(!store.canWrite)
      }
    }
  }

  // MARK: - 项目说明

  private var projectCard: some View {
    SettingsGroup("about.header.project") {
      Text("about.description")
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
      Text("about.disclaimer")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Divider()
      HStack(spacing: 10) {
        Link("about.link.home", destination: URL(string: "https://github.com/wolfprince12/squirrel-Panel")!)
        Link("about.link.issues", destination: URL(string: "https://github.com/wolfprince12/squirrel-Panel/issues")!)
        Link("about.link.rime", destination: URL(string: "https://rime.im")!)
        Link("about.link.squirrel", destination: URL(string: "https://github.com/rime/squirrel")!)
      }
      .font(.callout)
      Text("about.license")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Helpers

  private func openURL(_ string: String) {
    guard let url = URL(string: string) else { return }
    NSWorkspace.shared.open(url)
  }

  private func openWeChatSearch(account: String) {
    // 微信没有直接打开公众号的公开 URL 协议；这里复制账号名到剪贴板并提示用户搜索。
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(account, forType: .string)
    store.statusMessage = String(format: String(localized: "promo.yaozhi.copied"), account)
  }
}

// MARK: - Promotion Row

private struct PromotionRow: View {
  let icon: String
  let iconColor: Color
  let title: LocalizedStringKey
  let subtitle: LocalizedStringKey
  let description: LocalizedStringKey
  let actionTitle: LocalizedStringKey
  let action: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: icon)
        .font(.title2)
        .foregroundStyle(iconColor)
        .frame(width: 40, height: 40)
        .background(iconColor.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(title)
            .font(.headline)
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer()

      Button(action: action) {
        Text(actionTitle)
      }
      .controlSize(.small)
    }
  }
}

// MARK: - Shared Subviews

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
      Button("generic.open") { SquirrelBridge.reveal(url) }
        .controlSize(.small)
    }
  }
}
