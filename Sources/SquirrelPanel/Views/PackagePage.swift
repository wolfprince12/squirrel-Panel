//
//  PackagePage.swift
//  Squirrel Panel
//
//  词库包安装与卸载：基于内置注册表（DictionaryPackages.json）的精选包管理。
//

import SwiftUI

struct PackagePage: View {
  @EnvironmentObject private var store: SettingsStore
  @State private var packages: [DictionaryPackage] = []
  @State private var statuses: [String: PackageStatus] = [:]
  @State private var busyID: String? = nil
  @State private var logText: String = ""
  @State private var logTitle: String = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        SettingsGroup("package.title") {
          Text("package.intro")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        ForEach(packages) { pkg in
          PackageCard(
            pkg: pkg,
            status: statuses[pkg.id] ?? .notInstalled,
            busy: busyID == pkg.id,
            onInstall: { install(pkg) },
            onUninstall: { uninstall(pkg) }
          )
        }

        if !logText.isEmpty {
          SettingsGroup(LocalizedStringKey(logTitle)) {
            ScrollView {
              Text(logText)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(maxHeight: 160)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
          }
        }
      }
      .padding(20)
    }
    .onAppear(perform: reload)
  }

  private func reload() {
    packages = DictionaryPackageManager.loadRegistry()
    var st: [String: PackageStatus] = [:]
    for p in packages {
      st[p.id] = DictionaryPackageManager.status(of: p, environment: store.environment)
    }
    statuses = st
  }

  private func install(_ pkg: DictionaryPackage) {
    busyID = pkg.id
    logTitle = String(format: String(localized: "package.log.install"), pkg.name)
    logText = String(localized: "package.log.downloading")
    Task {
      do {
        let manifest = try await DictionaryPackageManager.install(pkg: pkg, environment: store.environment)
        await MainActor.run {
          logText = String(format: String(localized: "package.log.installed"), "\(manifest.addedFiles.count)")
          busyID = nil
          store.reload()
          reload()
        }
      } catch {
        await MainActor.run {
          logText = String(format: String(localized: "package.log.error"), error.localizedDescription)
          busyID = nil
        }
      }
    }
  }

  private func uninstall(_ pkg: DictionaryPackage) {
    busyID = pkg.id
    logTitle = String(format: String(localized: "package.log.uninstall"), pkg.name)
    logText = String(localized: "package.log.removing")
    Task {
      do {
        try await DictionaryPackageManager.uninstall(pkg: pkg, environment: store.environment)
        await MainActor.run {
          logText = String(localized: "package.log.removed")
          busyID = nil
          store.reload()
          reload()
        }
      } catch {
        await MainActor.run {
          logText = String(format: String(localized: "package.log.error"), error.localizedDescription)
          busyID = nil
        }
      }
    }
  }
}

struct PackageCard: View {
  let pkg: DictionaryPackage
  let status: PackageStatus
  let busy: Bool
  let onInstall: () -> Void
  let onUninstall: () -> Void

  private var statusLabel: String {
    switch status {
    case .notInstalled: return String(localized: "package.status.notInstalled")
    case .installed: return String(localized: "package.status.installed")
    case .external: return String(localized: "package.status.external")
    }
  }
  private var statusColor: Color {
    switch status {
    case .notInstalled: return .secondary
    case .installed: return .green
    case .external: return .orange
    }
  }

  var body: some View {
    SettingsGroup("") {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(pkg.name).font(.headline)
            Text(pkg.author).font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          HStack(spacing: 4) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusLabel).font(.caption).foregroundStyle(statusColor)
          }
        }
        Text(pkg.description)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 10) {
          switch status {
          case .installed:
            Button("package.button.uninstall", action: onUninstall)
              .controlSize(.small)
          case .external:
            Button("package.button.manage", action: onInstall)
              .controlSize(.small)
              .buttonStyle(.borderedProminent)
          case .notInstalled:
            Button("package.button.install", action: onInstall)
              .controlSize(.small)
              .buttonStyle(.borderedProminent)
          }
          if let url = URL(string: pkg.homepage) {
            Link("package.button.homepage", destination: url)
              .controlSize(.small)
          }
          if busy { ProgressView().controlSize(.small) }
          Spacer()
        }
      }
    }
  }
}
