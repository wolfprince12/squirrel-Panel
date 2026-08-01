//
//  AboutPage.swift
//  Squirrel Panel
//

import SwiftUI
import AppKit

struct AboutPage: View {
  @EnvironmentObject private var store: SettingsStore
  @Binding var showingResetAlert: Bool

  // 软件更新检查
  @State private var updateState: UpdateCheckState = .idle
  @State private var latestVersion: String?
  @State private var releaseURL: String?

  // 恢复鼠须管默认设置
  @State private var showingSquirrelResetAlert = false

  private var panelVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? String(localized: "generic.dev")
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        headerCard
        updateCard
        developerCard
        promotionSection
        statusCard
        pathsCard
        maintenanceCard
        projectCard
      }
      .padding(20)
    }
    .onAppear(perform: checkForUpdates)
    .alert("alert.squirrelResetTitle", isPresented: $showingSquirrelResetAlert) {
      Button("alert.cancel", role: .cancel) {}
      Button("alert.squirrelReset", role: .destructive) { store.resetSquirrelDefaults() }
    } message: {
      Text("alert.squirrelResetMessage")
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

  // MARK: - 软件更新检查

  private var updateCard: some View {
    SettingsGroup("about.header.update") {
      HStack(spacing: 12) {
        switch updateState {
        case .idle:
          Image(systemName: "arrow.up.circle")
            .foregroundStyle(.secondary)
            .font(.title3)
        case .checking:
          ProgressView().controlSize(.small)
        case .upToDate:
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .font(.title3)
        case .available:
          Image(systemName: "arrow.up.circle.fill")
            .foregroundStyle(.orange)
            .font(.title3)
        case .failed:
          Image(systemName: "exclamationmark.circle")
            .foregroundStyle(.secondary)
            .font(.title3)
        }

        VStack(alignment: .leading, spacing: 2) {
          Text(updateStatusText)
            .font(.callout)
          if let latestVersion, updateState == .available {
            Text(String(format: String(localized: "about.update.latest"), latestVersion))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Spacer()

        switch updateState {
        case .available:
          if let url = releaseURL, let dest = URL(string: url) {
            Link("about.update.download", destination: dest)
              .controlSize(.small)
              .buttonStyle(.borderedProminent)
          }
        case .failed:
          Button("about.update.retry") { checkForUpdates() }
            .controlSize(.small)
        default:
          Button("about.update.check") { checkForUpdates() }
            .controlSize(.small)
        }
      }
    }
  }

  private var updateStatusText: LocalizedStringKey {
    switch updateState {
    case .idle: return "about.update.idle"
    case .checking: return "about.update.checking"
    case .upToDate: return "about.update.upToDate"
    case .available: return "about.update.available"
    case .failed: return "about.update.failed"
    }
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
          actionTitle: "promo.yaozhi.saveQR",
          action: { saveQRCodeToDownloads() }
        )
        if let qr = qrCodeImage {
          Image(nsImage: qr)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: 240)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 3)
        }
        Divider()
        PromotionRow(
          icon: "doc.text.fill",
          iconColor: .indigo,
          title: "promo.dealv.title",
          subtitle: "promo.dealv.subtitle",
          description: "promo.dealv.description",
          actionTitle: "promo.dealv.action",
          action: { openURL("https://www.dealv.cn") }
        )
        Divider()
        PromotionRow(
          icon: "command",
          iconColor: .cyan,
          title: "promo.dsondt.title",
          subtitle: "promo.dsondt.subtitle",
          description: "promo.dsondt.description",
          actionTitle: "promo.dsondt.action",
          action: { openURL("https://github.com/wolfprince12/DSonDT") }
        )
      }
    }
  }

  private var qrCodeImage: NSImage? {
    guard let url = Bundle.main.url(forResource: "YaozhiQRCode", withExtension: "jpg") else { return nil }
    return NSImage(contentsOf: url)
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
      Divider()
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("about.squirrelReset.title")
          Text("about.squirrelReset.subtitle")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("about.squirrelReset.button", role: .destructive) { showingSquirrelResetAlert = true }
          .disabled(!store.environment.isInstalled)
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

  // MARK: - 更新检查逻辑

  enum UpdateCheckState {
    case idle
    case checking
    case upToDate
    case available
    case failed
  }

  private func checkForUpdates() {
    guard updateState != .checking else { return }
    updateState = .checking
    let currentVersion = panelVersion
    let repoAPI = "https://api.github.com/repos/wolfprince12/squirrel-Panel/releases/latest"
    guard let url = URL(string: repoAPI) else {
      updateState = .failed
      return
    }
    var req = URLRequest(url: url, timeoutInterval: 20)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    req.setValue("SquirrelPanel/\(panelVersion)", forHTTPHeaderField: "User-Agent")
    Task {
      do {
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
          await MainActor.run { updateState = .failed }
          return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = obj["tag_name"] as? String else {
          await MainActor.run { updateState = .failed }
          return
        }
        // tag_name 形如 "v0.3.2"，去掉前缀 v 再比较
        let remote = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        let htmlURL = obj["html_url"] as? String
        await MainActor.run {
          latestVersion = remote
          releaseURL = htmlURL
          updateState = Self.compareVersion(current: currentVersion, remote: remote) ? .available : .upToDate
        }
      } catch {
        await MainActor.run { updateState = .failed }
      }
    }
  }

  /// 简单版本比较：remote > current 时返回 true
  private static func compareVersion(current: String, remote: String) -> Bool {
    let curParts = current.split(separator: ".").compactMap { Int($0) }
    let remParts = remote.split(separator: ".").compactMap { Int($0) }
    let maxLen = max(curParts.count, remParts.count)
    for i in 0..<maxLen {
      let c = i < curParts.count ? curParts[i] : 0
      let r = i < remParts.count ? remParts[i] : 0
      if r > c { return true }
      if r < c { return false }
    }
    return false
  }

  // MARK: - Helpers

  private func openURL(_ string: String) {
    guard let url = URL(string: string) else { return }
    NSWorkspace.shared.open(url)
  }

  private func saveQRCodeToDownloads() {
    guard let source = Bundle.main.url(forResource: "YaozhiQRCode", withExtension: "jpg"),
          let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
      store.statusMessage = String(localized: "promo.yaozhi.saveFailed")
      return
    }
    let destination = downloads.appendingPathComponent("爻知云AI_公众号二维码.jpg")
    do {
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.copyItem(at: source, to: destination)
      store.statusMessage = String(localized: "promo.yaozhi.saved")
      NSWorkspace.shared.activateFileViewerSelecting([destination])
    } catch {
      store.statusMessage = String(localized: "promo.yaozhi.saveFailed")
    }
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
