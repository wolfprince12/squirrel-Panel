//
//  DeployPage.swift
//  Squirrel Panel
//
//  部署与排障：一键重新部署 + 日志回显 + 方案勾选 + 无可用方案检测。
//

import SwiftUI

struct DeployReportModel {
  var success: Bool = false
  var logText: String = ""
  var availableSchemas: [RimeSchema] = []
  var enabledSchemaIDs: [String] = []
  var missingSchemaIDs: [String] = []
  var durationMs: Int = 0
  var performed = false
}

struct DeployPage: View {
  @Environment(SettingsStore.self) private var store
  @State private var report = DeployReportModel()
  @State private var busy = false
  @State private var selectedIDs: [String] = []
  @State private var available: [RimeSchema] = []
  @State private var message = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        SettingsGroup("deploy.title") {
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text("deploy.redeploy.title")
              Text("deploy.redeploy.hint")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: runDeploy) {
              if busy { ProgressView().controlSize(.small) }
              else { Text("deploy.button.redeploy") }
            }
            .disabled(busy || !store.environment.isInstalled)
            .buttonStyle(.borderedProminent)
          }

          if report.performed {
            DeployResultBanner(report: report)
          }
        }

        if report.performed {
          SettingsGroup("deploy.log.title") {
            ScrollView {
              Text(report.logText)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(maxHeight: 200)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
          }

          if !report.missingSchemaIDs.isEmpty {
            SettingsGroup("deploy.missing.title") {
              Banner(kind: .error,
                     text: String(format: String(localized: "deploy.missing.text"),
                                  report.missingSchemaIDs.joined(separator: ", ")),
                     action: nil)
            }
          }

          SettingsGroup("deploy.schemas.title") {
            Text("deploy.schemas.hint")
              .font(.caption)
              .foregroundStyle(.secondary)
            ForEach(available) { schema in
              Toggle(isOn: Binding(
                get: { selectedIDs.contains(schema.id) },
                set: { on in
                  if on {
                    if !selectedIDs.contains(schema.id) { selectedIDs.append(schema.id) }
                  } else {
                    selectedIDs.removeAll { $0 == schema.id }
                  }
                })) {
                VStack(alignment: .leading) {
                  Text(schema.name)
                  Text(schema.subtitle).font(.caption).foregroundStyle(.secondary)
                }
              }
            }
            HStack {
              Button("deploy.schemas.apply", action: applySchemas)
                .disabled(busy || selectedIDs.isEmpty)
                .buttonStyle(.borderedProminent)
              Spacer()
              if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        }
      }
      .padding(20)
    }
    .onAppear(perform: refresh)
  }

  private func refresh() {
    available = SchemaCatalog.scan(environment: store.environment)
    selectedIDs = SchemaCatalog.enabledSchemaIDs(
      patch: CustomYAMLFile(fileURL: RimeEnvironment.userDirectory.appending(path: "default.custom.yaml")),
      environment: store.environment)
  }

  private func runDeploy() {
    busy = true
    message = ""
    Task {
      let r = await DeployManager.deployAndReport(environment: store.environment)
      await MainActor.run {
        report = DeployReportModel(
          success: r.success,
          logText: r.logText,
          availableSchemas: r.availableSchemas,
          enabledSchemaIDs: r.enabledSchemaIDs,
          missingSchemaIDs: r.missingSchemaIDs,
          durationMs: r.durationMs,
          performed: true)
        available = r.availableSchemas
        selectedIDs = r.enabledSchemaIDs
        busy = false
        store.reload()
      }
    }
  }

  private func applySchemas() {
    busy = true
    Task {
      let patch = CustomYAMLFile(fileURL: RimeEnvironment.userDirectory.appending(path: "default.custom.yaml"))
      patch.load()
      SchemaCatalog.setEnabledSchemas(selectedIDs, patch: patch)
      try? patch.save()
      do { try SquirrelBridge.deploy(environment: store.environment) } catch {}
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      await MainActor.run {
        store.reload()
        message = String(localized: "deploy.schemas.applied")
        busy = false
        runDeploy()
      }
    }
  }
}

struct DeployResultBanner: View {
  let report: DeployReportModel
  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: report.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(report.success ? Color.green : Color.orange)
      Text(report.success ? String(localized: "deploy.result.ok") : String(localized: "deploy.result.warn"))
        .font(.callout)
      Spacer()
      Text(String(format: String(localized: "deploy.result.duration"), "\(report.durationMs)"))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background((report.success ? Color.green : Color.orange).opacity(0.10))
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }
}
