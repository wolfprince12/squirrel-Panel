//
//  UpdateCenter.swift
//  Squirrel Panel
//
//  集中管理三类更新检查：
//    1. 本软件（squirrel-Panel）自身更新
//    2. 鼠须管（Squirrel.app）输入法本体更新
//    3. 第三方词库包（如雾凇拼音）更新
//  由 RootView 在软件打开时统一触发一次，避免进入对应面板才检查。
//

import SwiftUI
import Foundation

/// 更新检查状态（软件自身 / 鼠须管本体共用）
enum UpdateCheckState: Equatable {
  case idle
  case checking
  case upToDate
  case available
  case failed
}

@MainActor
final class UpdateCenter: ObservableObject {
  // MARK: - 软件自身更新
  @Published var appUpdateState: UpdateCheckState = .idle
  @Published var appLatestVersion: String?
  @Published var appReleaseURL: String?
  @Published var appUpdateUsedMirror = false

  // MARK: - 鼠须管输入法更新
  @Published var squirrelUpdateState: UpdateCheckState = .idle
  @Published var squirrelLatestVersion: String?
  @Published var squirrelReleaseURL: String?
  @Published var squirrelUpdateUsedMirror = false

  // MARK: - 第三方词库包更新
  @Published var dictionaryUpdateStates: [String: PackageUpdateState] = [:]
  @Published var dictionaryCheckingAll = false

  private let store: SettingsStore

  init(store: SettingsStore) {
    self.store = store
  }

  /// 软件启动时统一触发三类检查各一次
  func checkAllOnLaunch() {
    checkAppUpdate()
    checkSquirrelUpdate()
    checkDictionaryUpdates()
  }

  // MARK: - 软件自身更新

  func checkAppUpdate() {
    guard appUpdateState != .checking else { return }
    appUpdateState = .checking
    appUpdateUsedMirror = false
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    Task {
      do {
        let result = try await GitHubMirrorFetch.fetchLatestRelease(repo: "wolfprince12/squirrel-Panel")
        let remote = result.tag.hasPrefix("v") ? String(result.tag.dropFirst()) : result.tag
        let usedMirror = result.usedURL != "https://api.github.com/repos/wolfprince12/squirrel-Panel/releases/latest"
        await MainActor.run {
          appLatestVersion = remote
          appReleaseURL = result.htmlURL
          appUpdateUsedMirror = usedMirror
          appUpdateState = Self.compareVersion(current: currentVersion, remote: remote) ? .available : .upToDate
        }
      } catch {
        await MainActor.run { appUpdateState = .failed }
      }
    }
  }

  // MARK: - 鼠须管输入法更新

  func checkSquirrelUpdate() {
    guard store.environment.isInstalled else {
      squirrelUpdateState = .idle
      return
    }
    guard squirrelUpdateState != .checking else { return }
    squirrelUpdateState = .checking
    squirrelUpdateUsedMirror = false
    let currentVersion = store.environment.version ?? ""
    Task {
      do {
        let result = try await GitHubMirrorFetch.fetchLatestRelease(repo: "rime/squirrel")
        let remote = result.tag.hasPrefix("v") ? String(result.tag.dropFirst()) : result.tag
        let usedMirror = result.usedURL != "https://api.github.com/repos/rime/squirrel/releases/latest"
        await MainActor.run {
          squirrelLatestVersion = remote
          squirrelReleaseURL = result.htmlURL
          squirrelUpdateUsedMirror = usedMirror
          let isNewer = !currentVersion.isEmpty && Self.compareVersion(current: currentVersion, remote: remote)
          squirrelUpdateState = isNewer ? .available : .upToDate
        }
      } catch {
        await MainActor.run { squirrelUpdateState = .failed }
      }
    }
  }

  // MARK: - 第三方词库包更新

  func checkDictionaryUpdates() {
    guard !dictionaryCheckingAll else { return }
    let packages = DictionaryPackageManager.loadRegistry()
    var statuses: [String: PackageStatus] = [:]
    for p in packages {
      statuses[p.id] = DictionaryPackageManager.status(of: p, environment: store.environment)
    }
    var draft = dictionaryUpdateStates
    for p in packages where (statuses[p.id] ?? .notInstalled).isInstalled {
      draft[p.id] = .checking
    }
    dictionaryUpdateStates = draft
    dictionaryCheckingAll = true
    Task {
      await withThrowingTaskGroup(of: (String, PackageUpdateState).self) { group in
        for p in packages where (statuses[p.id] ?? .notInstalled).isInstalled {
          group.addTask { (p.id, await Self.computeUpdateState(for: p, status: statuses[p.id] ?? .notInstalled)) }
        }
        while let result = try? await group.next() {
          let (id, st) = result
          await MainActor.run { self.dictionaryUpdateStates[id] = st }
        }
      }
      await MainActor.run { dictionaryCheckingAll = false }
    }
  }

  func checkDictionaryOne(_ pkg: DictionaryPackage) {
    let status = DictionaryPackageManager.status(of: pkg, environment: store.environment)
    guard case .installed = status else { return }
    dictionaryUpdateStates[pkg.id] = .checking
    Task {
      let st = await Self.computeUpdateState(for: pkg, status: status)
      await MainActor.run { self.dictionaryUpdateStates[pkg.id] = st }
    }
  }

  private static func computeUpdateState(for pkg: DictionaryPackage, status: PackageStatus) async -> PackageUpdateState {
    guard case .installed(let manifest) = status else { return .notApplicable }
    do {
      if isReleaseAssetPackage(pkg) {
        // release asset 包：优先按 release tag 比对
        let remote = try await DictionaryPackageManager.fetchLatestRelease(pkg: pkg)
        if let installedTag = manifest.installedTag?.trimmingCharacters(in: .whitespacesAndNewlines),
           !installedTag.isEmpty {
          return installedTag == remote.tag ? .upToDate : .available
        }
        // 旧版 manifest 可能没有 installedTag（commit-based 安装记录迁移而来），回退到 SHA 比对
        if let installedCommit = normalizedSHA(manifest.installedCommit) {
          let remoteCommit = try await DictionaryPackageManager.fetchLatestCommit(pkg: pkg)
          guard let remoteNorm = normalizedSHA(remoteCommit.sha) else { return .unknown }
          return installedCommit == remoteNorm ? .upToDate : .available
        }
        return .unknown
      } else {
        // commit-based 包：按 commit SHA 比对
        let remote = try await DictionaryPackageManager.fetchLatestCommit(pkg: pkg)
        guard let installedNorm = normalizedSHA(manifest.installedCommit),
              let remoteNorm = normalizedSHA(remote.sha) else {
          return .unknown
        }
        return installedNorm == remoteNorm ? .upToDate : .available
      }
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  private static func isReleaseAssetPackage(_ pkg: DictionaryPackage) -> Bool {
    return pkg.releaseAsset?.isEmpty == false
  }

  /// 归一化 SHA：去空白、转小写，便于跨来源（API / HTML / 清单）比对。
  private static func normalizedSHA(_ sha: String?) -> String? {
    guard let sha = sha?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !sha.isEmpty else { return nil }
    return sha
  }

  // MARK: - 版本比较

  /// 简单版本比较：remote > current 时返回 true
  static func compareVersion(current: String, remote: String) -> Bool {
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
}
