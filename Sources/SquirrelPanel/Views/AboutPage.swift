//
//  AboutPage.swift
//  Squirrel Panel
//

import SwiftUI
import AppKit

struct AboutPage: View {
  @EnvironmentObject private var store: SettingsStore
  @EnvironmentObject private var updateCenter: UpdateCenter
  @Binding var showingResetAlert: Bool

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
        squirrelUpdateCard
        developerCard
        promotionSection
        statusCard
        pathsCard
        maintenanceCard
        projectCard
      }
      .padding(20)
    }
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
        updateStatusIcon(state: updateCenter.appUpdateState)

        VStack(alignment: .leading, spacing: 2) {
          Text(updateStatusText)
            .font(.callout)
          if let appLatestVersion = updateCenter.appLatestVersion, updateCenter.appUpdateState == .available {
            Text(String(format: String(localized: "about.update.latest"), appLatestVersion))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if updateCenter.appUpdateUsedMirror && updateCenter.appUpdateState != .failed {
            Text(String(localized: "about.update.viaMirror"))
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }

        Spacer()

        switch updateCenter.appUpdateState {
        case .available:
          if let url = updateCenter.appReleaseURL, let dest = URL(string: url) {
            Link("about.update.download", destination: dest)
              .controlSize(.small)
              .buttonStyle(.borderedProminent)
          }
        case .failed:
          Button("about.update.retry") { updateCenter.checkAppUpdate() }
            .controlSize(.small)
        default:
          Button("about.update.check") { updateCenter.checkAppUpdate() }
            .controlSize(.small)
        }
      }
    }
  }

  @ViewBuilder
  private func updateStatusIcon(state: UpdateCheckState) -> some View {
    switch state {
    case .checking:
      ProgressView()
        .controlSize(.small)
        .frame(width: 30, height: 30)
    default:
      let (name, tint): (String, Color) = {
        switch state {
        case .idle: return ("arrow.up.circle", .secondary)
        case .upToDate: return ("checkmark.circle.fill", .green)
        case .available: return ("arrow.up.circle.fill", .orange)
        case .failed: return ("exclamationmark.circle", .red)
        default: return ("questionmark.circle", .secondary)
        }
      }()
      Image(systemName: name)
        .font(.callout)
        .foregroundStyle(tint)
        .frame(width: 30, height: 30)
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
  }

  private var updateStatusText: LocalizedStringKey {
    switch updateCenter.appUpdateState {
    case .idle: return "about.update.idle"
    case .checking: return "about.update.checking"
    case .upToDate: return "about.update.upToDate"
    case .available: return "about.update.available"
    case .failed: return "about.update.failed"
    }
  }

  // MARK: - 鼠须管输入法更新检查

  private var squirrelUpdateCard: some View {
    SettingsGroup("about.header.squirrelUpdate") {
      HStack(spacing: 12) {
        updateStatusIcon(state: updateCenter.squirrelUpdateState)

        VStack(alignment: .leading, spacing: 2) {
          Text(squirrelUpdateStatusText)
            .font(.callout)
          if let squirrelLatestVersion = updateCenter.squirrelLatestVersion, updateCenter.squirrelUpdateState == .available {
            Text(String(format: String(localized: "about.squirrelUpdate.latest"), squirrelLatestVersion))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if updateCenter.squirrelUpdateUsedMirror && updateCenter.squirrelUpdateState != .failed {
            Text(String(localized: "about.update.viaMirror"))
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }

        Spacer()

        switch updateCenter.squirrelUpdateState {
        case .available:
          if let url = updateCenter.squirrelReleaseURL, let dest = URL(string: url) {
            Link("about.squirrelUpdate.download", destination: dest)
              .controlSize(.small)
              .buttonStyle(.borderedProminent)
          }
        case .failed:
          Button("about.squirrelUpdate.retry") { updateCenter.checkSquirrelUpdate() }
            .controlSize(.small)
        default:
          Button("about.squirrelUpdate.check") { updateCenter.checkSquirrelUpdate() }
            .controlSize(.small)
            .disabled(!store.environment.isInstalled)
        }
      }
    }
  }

  private var squirrelUpdateStatusText: LocalizedStringKey {
    if !store.environment.isInstalled {
      return "about.squirrelUpdate.notInstalled"
    }
    switch updateCenter.squirrelUpdateState {
    case .idle: return "about.squirrelUpdate.idle"
    case .checking: return "about.squirrelUpdate.checking"
    case .upToDate: return "about.squirrelUpdate.upToDate"
    case .available: return "about.squirrelUpdate.available"
    case .failed: return "about.squirrelUpdate.failed"
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
      StatusRow(
        icon: "hammer.fill",
        tint: .secondary,
        label: String(localized: "about.panel.version"),
        value: "v\(panelVersion)")
      Divider()
      StatusRow(
        icon: store.environment.isInstalled ? "checkmark.circle.fill" : "xmark.circle.fill",
        tint: store.environment.isInstalled ? .green : .red,
        label: String(localized: "about.squirrel.installed"),
        value: store.environment.isInstalled
          ? String(format: String(localized: "about.squirrel.version"), store.environment.version ?? String(localized: "generic.unknown"))
          : String(localized: "about.squirrel.notInstalled"))
      Divider()
      StatusRow(
        icon: store.environment.isRunning ? "checkmark.circle.fill" : "xmark.circle.fill",
        tint: store.environment.isRunning ? .green : .orange,
        label: String(localized: "about.squirrel.process"),
        value: store.environment.isRunning
          ? String(localized: "about.squirrel.running")
          : String(localized: "about.squirrel.notRunning"))
      Divider()
      StatusRow(
        icon: store.environment.isUserDirectoryReady ? "folder.badge.person.crop" : "folder.badge.exclamationmark",
        tint: store.environment.isUserDirectoryReady ? .green : .orange,
        label: String(localized: "about.userDir"),
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
      MaintenanceRow(
        icon: "arrow.clockwise",
        tint: .blue,
        title: String(localized: "about.reload.title"),
        subtitle: String(localized: "about.reload.subtitle"),
        actionTitle: String(localized: "about.reload.button"),
        action: { store.reload() })
      Divider()
      MaintenanceRow(
        icon: "gobackward",
        tint: .orange,
        title: String(localized: "about.reset.title"),
        subtitle: String(localized: "about.reset.subtitle"),
        actionTitle: String(localized: "about.reset.button"),
        isDestructive: true,
        action: { showingResetAlert = true })
      .disabled(!store.canWrite)
      Divider()
      MaintenanceRow(
        icon: "exclamationmark.triangle.fill",
        tint: .red,
        title: String(localized: "about.squirrelReset.title"),
        subtitle: String(localized: "about.squirrelReset.subtitle"),
        actionTitle: String(localized: "about.squirrelReset.button"),
        isDestructive: true,
        action: { showingSquirrelResetAlert = true })
      .disabled(!store.environment.isInstalled)
      Divider()
      MaintenanceRow(
        icon: "text.alignleft",
        tint: .teal,
        title: String(localized: "about.fixWhitespace.title"),
        subtitle: String(localized: "about.fixWhitespace.subtitle"),
        actionTitle: String(localized: "about.fixWhitespace.button"),
        action: { store.fixWhitespaceInConfigFiles() })
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

private struct StatusRow: View {
  let icon: String
  let tint: Color
  let label: String
  let value: String

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: icon)
        .font(.caption2)
        .foregroundStyle(tint)
        .frame(width: 22, height: 22)
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

      Text(label)

      Spacer()

      Text(value)
        .foregroundStyle(.secondary)
    }
  }
}

private struct MaintenanceRow: View {
  let icon: String
  let tint: Color
  let title: String
  let subtitle: String
  let actionTitle: String
  var isDestructive: Bool = false
  let action: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .font(.caption)
        .foregroundStyle(tint)
        .frame(width: 28, height: 28)
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer()

      if isDestructive {
        Button(actionTitle, role: .destructive, action: action)
          .controlSize(.small)
      } else {
        Button(actionTitle, action: action)
          .controlSize(.small)
      }
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
