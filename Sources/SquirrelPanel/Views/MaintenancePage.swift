//
//  MaintenancePage.swift
//  Squirrel Panel
//
//  维护面板：集中收纳所有「修复型」功能，并新增「部署 YAML 错误精确诊断」。
//  从「关于」页的维护模块与「雾凇拼音」页的急救模块迁移而来，避免修复能力散落各处。
//

import SwiftUI
import AppKit

struct MaintenancePage: View {
  @EnvironmentObject private var store: SettingsStore
  @EnvironmentObject private var ice: RimeIceConfigStore

  // 三类破坏性操作的二次确认
  @State private var showingResetAlert = false
  @State private var showingSquirrelResetAlert = false
  @State private var showingIceResetAlert = false

  // 部署诊断状态
  @State private var diagnosing = false
  @State private var diagnoseResult: DeployManager.DiagnoseResult?
  @State private var diagnoseRan = false
  @State private var showRawLog = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        maintenanceSection
        diagnoseSection
      }
      .padding(20)
    }
    .alert("alert.resetTitle", isPresented: $showingResetAlert) {
      Button("alert.cancel", role: .cancel) {}
      Button("alert.reset", role: .destructive) { store.resetManagedSettings() }
    } message: {
      Text("alert.resetMessage")
    }
    .alert("alert.squirrelResetTitle", isPresented: $showingSquirrelResetAlert) {
      Button("alert.cancel", role: .cancel) {}
      Button("alert.squirrelReset", role: .destructive) { store.resetSquirrelDefaults() }
    } message: {
      Text("alert.squirrelResetMessage")
    }
    .alert("alert.iceEmergencyResetTitle", isPresented: $showingIceResetAlert) {
      Button("alert.cancel", role: .cancel) {}
      Button("alert.iceEmergencyReset", role: .destructive) { ice.resetAllRimeIceConfigs() }
    } message: {
      Text("alert.iceEmergencyResetMessage")
    }
  }

  // MARK: - 维护（修复型功能 + 急救功能合并）

  private var maintenanceSection: some View {
    SettingsGroup("maintenance.title") {
      VStack(alignment: .leading, spacing: 12) {
        Text("maintenance.hint")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        VStack(spacing: 0) {
          MaintenanceRow(
            icon: "arrow.clockwise",
            tint: .blue,
            title: String(localized: "about.reload.title"),
            subtitle: String(localized: "about.reload.subtitle"),
            actionTitle: String(localized: "about.reload.button"),
            action: { store.reload() })
          Divider().padding(.leading, 44)
          MaintenanceRow(
            icon: "text.alignleft",
            tint: .teal,
            title: String(localized: "about.fixWhitespace.title"),
            subtitle: String(localized: "about.fixWhitespace.subtitle"),
            actionTitle: String(localized: "about.fixWhitespace.button"),
            action: { store.fixWhitespaceInConfigFiles() })
          Divider().padding(.leading, 44)
          MaintenanceRow(
            icon: "gobackward",
            tint: .orange,
            title: String(localized: "about.reset.title"),
            subtitle: String(localized: "about.reset.subtitle"),
            actionTitle: String(localized: "about.reset.button"),
            isDestructive: true,
            action: { showingResetAlert = true })
          .disabled(!store.canWrite)
          Divider().padding(.leading, 44)
          MaintenanceRow(
            icon: "exclamationmark.triangle.fill",
            tint: .red,
            title: String(localized: "about.squirrelReset.title"),
            subtitle: String(localized: "about.squirrelReset.subtitle"),
            actionTitle: String(localized: "about.squirrelReset.button"),
            isDestructive: true,
            action: { showingSquirrelResetAlert = true })
          .disabled(!store.environment.isInstalled)
          Divider().padding(.leading, 44)
          MaintenanceRow(
            icon: "snowflake",
            tint: .purple,
            title: String(localized: "riceice.emergencyReset"),
            subtitle: String(localized: "riceice.emergencyReset.hint"),
            actionTitle: String(localized: "riceice.emergencyReset"),
            isDestructive: true,
            action: { showingIceResetAlert = true })
          .disabled(!store.environment.isInstalled)
        }
      }
    }
  }

  // MARK: - 部署 YAML 错误精确诊断（新增）

  private var diagnoseSection: some View {
    SettingsGroup("diagnose.title") {
      VStack(alignment: .leading, spacing: 12) {
        Text("diagnose.hint")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack {
          if diagnosing {
            ProgressView().controlSize(.small)
            Text("diagnose.running")
              .font(.callout)
              .foregroundStyle(.secondary)
          } else {
            Button("diagnose.button.run") { runDiagnose() }
              .buttonStyle(.borderedProminent)
              .disabled(!store.environment.isInstalled)
          }
          Spacer()
          if diagnoseRan, let result = diagnoseResult {
            Text(String(format: String(localized: "diagnose.duration"), "\(result.durationMs)"))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        if diagnoseRan, let result = diagnoseResult {
          if result.issues.isEmpty {
            Banner(kind: .info,
                   text: String(localized: "diagnose.clean"),
                   action: nil)
          } else {
            Banner(kind: .error,
                   text: String(format: String(localized: "diagnose.found"), result.issues.count),
                   action: nil)
            ForEach(result.issues) { issue in
              issueRow(issue)
              if issue.id != result.issues.last?.id { Divider() }
            }
          }

          if !result.rawLog.isEmpty {
            DisclosureGroup(isExpanded: $showRawLog) {
              ScrollView {
                Text(result.rawLog)
                  .font(.system(.caption, design: .monospaced))
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .textSelection(.enabled)
              }
              .frame(maxHeight: 200)
              .padding(8)
              .background(Color(nsColor: .textBackgroundColor))
              .clipShape(RoundedRectangle(cornerRadius: 6))
            } label: {
              Text("diagnose.rawLog")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
          }
        }
      }
    }
  }

  private func issueRow(_ issue: DeployManager.ConfigIssue) -> some View {
    let fileURL = URL(fileURLWithPath: issue.path)
    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Image(systemName: "xmark.octagon.fill")
          .foregroundStyle(.red)
          .frame(width: 22, height: 22)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(issue.fileName)
              .font(.callout.bold())
            if let line = issue.line {
              Text(String(format: String(localized: "diagnose.lineCol"), "\(line)", "\(issue.column ?? 0)"))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          Text(issue.message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
      }
      HStack(spacing: 8) {
        Spacer()
        Text("diagnose.fixHint")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Button("generic.open") { SquirrelBridge.reveal(fileURL) }
          .controlSize(.small)
      }
    }
    .padding(.vertical, 4)
  }

  private func runDiagnose() {
    diagnosing = true
    diagnoseRan = false
    diagnoseResult = nil
    Task {
      let result = await DeployManager.diagnose(environment: store.environment)
      await MainActor.run {
        diagnoseResult = result
        diagnoseRan = true
        diagnosing = false
        if result.didStopSquirrel {
          store.reload()
        }
      }
    }
  }
}

// MARK: - 维护行（原 AboutPage 的 MaintenanceRow，迁移至此集中复用）

struct MaintenanceRow: View {
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
