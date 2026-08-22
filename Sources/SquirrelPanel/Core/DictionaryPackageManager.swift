//
//  DictionaryPackageManager.swift
//  Squirrel Panel
//
//  词库包（如雾凇拼音 rime-ice）的安装与卸载。
//
//  设计原则：做成「精选词库包管理器」，而非「装任意词库」。
//  App 内置一份注册表（Resources/DictionaryPackages.json），每条描述一个包的来源
//  与默认方案。安装/卸载全程基于「快照 + 备份 + 清单」三件套，严守底线：
//    - 只删除本面板自己装进去的文件；
//    - 安装前备份会被覆盖的文件，卸载时还原；
//    - 绝不动用户自己原有的其他文件。
//

import Foundation

struct DictionaryPackage: Identifiable, Codable {
  let id: String
  let name: String
  let name_en: String
  let description: String
  let description_en: String
  let sourceURL: String
  /// 若使用 GitHub Release asset 分发（如雾凇的 full.zip），填写 asset 文件名。
  /// 此时 sourceURL 应为原始 release asset URL，下载时会自动构造南大镜像等候选地址。
  let releaseAsset: String?
  /// 用于更新检查的仓库信息（也可从 sourceURL 推导）
  let repoOwner: String?
  let repoName: String?
  let branch: String?
  let defaultSchema: String
  let homepage: String
  let author: String
  /// 包类型："dictionary"（默认，整包 zip）或 "grammar"（单文件语言模型）。
  /// 语法模型不走整包解压流程，而是下载单个 .gram 文件 + 写 default.custom.yaml 的 grammar 段。
  let type: String?

  /// 是否语法模型包（万象语法模型等）
  var isGrammar: Bool { type == "grammar" }

  /// 是否 AI 引擎包（AIEnergy 核心：Lua 叠加层 + Python 服务，部署到 Rime 目录）
  var isAIEngine: Bool { type == "aiengine" }

  /// 语法模型的语言名（由 releaseAsset 去掉 .gram 后缀得到，如 wanxiang-lts-zh-hans）
  var grammarLanguage: String {
    let asset = releaseAsset ?? "wanxiang-lts-zh-hans.gram"
    return asset.replacingOccurrences(of: ".gram", with: "")
  }

  /// 更新检查所用的 GitHub API 地址；缺少仓库信息时为 nil
  var updateCheckAPIURL: URL? {
    if let owner = repoOwner, let name = repoName, let branch = branch,
       !owner.isEmpty, !name.isEmpty, !branch.isEmpty,
       let url = URL(string: "https://api.github.com/repos/\(owner)/\(name)/commits?sha=\(branch)&per_page=1") {
      return url
    }
    // 兜底：从 sourceURL 解析 github.com/{owner}/{repo}/archive/refs/heads/{branch}.zip
    guard let comps = URLComponents(string: sourceURL),
          let host = comps.host, host == "github.com" else { return nil }
    let pc = comps.path.split(separator: "/").map(String.init)
    guard pc.count >= 5 else { return nil }
    let owner = pc[1], name = pc[2], branch = pc[4]
    return URL(string: "https://api.github.com/repos/\(owner)/\(name)/commits?sha=\(branch)&per_page=1")
  }
}

struct PackageManifest: Codable {
  var id: String
  var addedFiles: [String]          // 相对 Rime 目录的相对路径
  var backupDir: String             // 备份目录的绝对路径
  var defaultSchema: String
  var installedAt: Date
  var version: String
  var installedCommit: String?      // 安装时锁定的上游最新 commit，用于更新比对
  var installedTag: String?         // release asset 包记录 release tag，用于更新比对
  var installedSize: Int? = nil      // 语法模型：安装时记录的远程 .gram 文件字节数，用于更新比对
}

enum PackageStatus {
  case notInstalled
  case installed(PackageManifest)   // 由本面板安装并管理
  case external                     // 文件已存在，但非本面板安装
}

enum PackageManagerError: LocalizedError {
  case downloadFailed(String)
  case extractFailed(String)
  case notManagedByPanel
  case squirrelNotInstalled
  case grammarRequiresRimeIce
  case grammarMustBeUninstalledFirst
  case updateCheckFailed(String)
  case commandFailed(String, Int32)

  var errorDescription: String? {
    switch self {
    case .downloadFailed(let u): return String(format: String(localized: "package.error.download"), u)
    case .extractFailed(let m): return String(format: String(localized: "package.error.extract"), m)
    case .notManagedByPanel: return String(localized: "package.error.notManaged")
    case .squirrelNotInstalled: return String(localized: "error.squirrelNotInstalled")
    case .grammarRequiresRimeIce: return String(localized: "package.error.grammarRequiresRimeIce")
    case .grammarMustBeUninstalledFirst: return String(localized: "package.error.grammarMustBeUninstalledFirst")
    case .updateCheckFailed(let m): return String(format: String(localized: "package.error.updateCheck"), m)
    case .commandFailed(let c, let code): return String(format: String(localized: "error.commandFailed"), c, code)
    }
  }
}

enum DictionaryPackageManager {

  static let managedDirName = ".squirrel-panel"
  /// 安装时跳过的非运行时文件/目录（陈旧编译产物、仓库元数据、庞杂素材等）
  static let excludeFromInstall = Set([
    "build", ".git", ".github", "others", "__MACOSX",
    "AGENTS.md", "README.md", "LICENSE", ".gitignore", "recipe.yaml"
  ])

  // MARK: - 注册表

  static func loadRegistry() -> [DictionaryPackage] {
    guard let url = Bundle.main.url(forResource: "DictionaryPackages", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let list = try? JSONDecoder().decode([DictionaryPackage].self, from: data) else {
      return []
    }
    return list
  }

  // MARK: - 路径

  private static func rimeDir() -> URL { RimeEnvironment.userDirectory }
  private static func managedRoot() -> URL {
    rimeDir().appending(path: managedDirName, directoryHint: .isDirectory)
  }
  private static func manifestsDir() -> URL {
    managedRoot().appending(path: "manifests", directoryHint: .isDirectory)
  }
  private static func backupDir(for id: String) -> URL {
    managedRoot().appending(path: "backups/\(id)", directoryHint: .isDirectory)
  }
  private static func manifestURL(for id: String) -> URL {
    manifestsDir().appending(path: "\(id).json")
  }

  /// 语法模型（万象等）依赖雾凇拼音（rime_ice）方案才能生效：
  /// 面板写入的是 `rime_ice.custom.yaml` 的 grammar 段，且 octagram 加载模型需要 `rime_ice.prism`。
  /// 若 `rime_ice.schema.yaml` 不存在，说明雾凇未安装，语法模型没有挂载点，安装无意义。
  static func isRimeIceInstalled() -> Bool {
    let schemaFile = rimeDir().appending(path: "rime_ice.schema.yaml")
    return FileManager.default.fileExists(atPath: schemaFile.path(percentEncoded: false))
  }

  /// 查询注册表中某个 id 的包是否处于「已由本面板安装」状态。
  static func isPackageInstalled(id: String, environment: RimeEnvironment) -> Bool {
    guard let pkg = loadRegistry().first(where: { $0.id == id }) else { return false }
    if case .installed = status(of: pkg, environment: environment) { return true }
    return false
  }

  /// 对旧版 commit-based 包 manifest 补录一次当前远程 commit 作为基线。
  /// 早期安装流程未写入 installedCommit，导致更新检查永久返回 .unknown；
  /// 补录后用户无需重装即可看到「已是最新」。若远程获取失败则保持原状。
  static func backfillInstalledCommitIfNeeded(pkg: DictionaryPackage) async {
    guard pkg.releaseAsset?.isEmpty != false else { return }  // 仅 commit-based
    let env = RimeEnvironment.detect()
    guard case .installed(var manifest) = status(of: pkg, environment: env) else { return }
    guard manifest.installedCommit?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else { return }
    do {
      let remote = try await fetchLatestCommit(pkg: pkg)
      manifest.installedCommit = remote.sha
      let data = try JSONEncoder().encode(manifest)
      try data.write(to: manifestURL(for: pkg.id), options: .atomic)
    } catch {
      // 保持原状，更新检查仍返回 .unknown
    }
  }

  // MARK: - 状态

  static func status(of pkg: DictionaryPackage, environment: RimeEnvironment) -> PackageStatus {
    let mURL = manifestURL(for: pkg.id)
    if let data = try? Data(contentsOf: mURL),
       let manifest = try? JSONDecoder().decode(PackageManifest.self, from: data) {
      return .installed(manifest)
    }
    // 外部安装：默认方案的 schema 文件存在即视为已装（但非本面板管理）
    let schemaFile = rimeDir().appending(path: "\(pkg.defaultSchema).schema.yaml")
    if FileManager.default.fileExists(atPath: schemaFile.path(percentEncoded: false)) {
      return .external
    }
    return .notInstalled
  }

  // MARK: - 快照

  /// 递归列出目录下所有文件，返回相对路径（以 / 分隔）
  /// 注意：macOS 的 `FileManager.enumerator` 可能返回 `/private/var/...` 规范化路径，
  /// 而 `root` 可能是 `/var/...`，直接字符串替换会产生 `private/...` 这样的错误相对路径。
  /// 这里用 `pathComponents` 做前缀匹配，避免 `/var` 与 `/private/var` 的差异。
  private static func snapshotFiles(in root: URL) -> [String] {
    var result: [String] = []
    guard let enumerator = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return result }
    let baseURL = root.resolvingSymlinksInPath()
    let baseComponents = baseURL.pathComponents
    for case let url as URL in enumerator {
      if url.hasDirectoryPath { continue }
      let resolved = url.resolvingSymlinksInPath()
      let components = resolved.pathComponents
      guard components.count > baseComponents.count else { continue }
      let relComponents = components.dropFirst(baseComponents.count)
      let clean = relComponents.joined(separator: "/")
      if !clean.isEmpty { result.append(clean) }
    }
    return result
  }

  /// 判断某条相对路径是否应该被安装（排除非运行时文件、macOS 元数据等）
  private static func shouldInstall(_ rel: String) -> Bool {
    let parts = rel.split(separator: "/").map(String.init)
    guard let top = parts.first else { return false }
    if Self.excludeFromInstall.contains(top) { return false }
    // 排除 AppleDouble 资源分支文件（._*）以及隐藏文件
    if let last = parts.last, last.hasPrefix(".") { return false }
    return true
  }

  // MARK: - 安装

  static func install(pkg: DictionaryPackage, environment: RimeEnvironment) async throws -> PackageManifest {
    guard environment.isInstalled else { throw PackageManagerError.squirrelNotInstalled }

    // 语法模型（万象等）：单文件 .gram + default.custom.yaml 的 grammar 段，走独立分支
    if pkg.isGrammar {
      return try await installGrammar(pkg: pkg, environment: environment)
    }

    // AI 引擎（AIEnergy）：lua 叠加层 + Python 服务，部署到 Rime 目录，走独立分支
    if pkg.isAIEngine {
      return try await installAIEngine(pkg: pkg, environment: environment)
    }

    let fm = FileManager.default
    let rime = rimeDir()
    try fm.createDirectory(at: rime, withIntermediateDirectories: true)
    try fm.createDirectory(at: manifestsDir(), withIntermediateDirectories: true)
    try fm.createDirectory(at: backupDir(for: pkg.id), withIntermediateDirectories: true)

    // 1. 先取上游最新版本信息，用于锁定下载版本和后续比对
    //    release asset 包用 release tag；commit-based 包用 commit SHA。
    let releaseTag: String?
    let commitSHA: String?
    if usesReleaseAsset(pkg) {
      releaseTag = try? await fetchLatestRelease(pkg: pkg).tag
      commitSHA = nil
    } else {
      releaseTag = nil
      commitSHA = try? await fetchLatestCommit(pkg: pkg).sha
    }

    // 2. 下载：release asset 包使用 release asset 候选 URL；commit-based 包使用精确 commit 归档
    let zipURL = try await download(from: installDownloadURLs(for: pkg, releaseTag: releaseTag, commitSHA: commitSHA))

    // 3. 解压到临时目录（ditto 非交互，可正确处理非常规文件名）
    let stage = FileManager.default.temporaryDirectory
      .appending(path: "squirrel-panel-\(pkg.id)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? fm.removeItem(at: stage)
    try fm.createDirectory(at: stage, withIntermediateDirectories: true)
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-x", "-k", zipURL.path(percentEncoded: false), stage.path(percentEncoded: false)]
    try ditto.run()
    ditto.waitUntilExit()
    guard ditto.terminationStatus == 0 else {
      throw PackageManagerError.extractFailed("ditto exit \(ditto.terminationStatus)")
    }

    // 4. 定位包根（处理内层文件夹，如 rime-ice-main 或 rime-ice-<sha>）
    let packageRoot = locatePackageRoot(in: stage)

    // 5. 枚举要安装的文件（排除非运行时文件与 macOS 元数据）
    let allFiles = snapshotFiles(in: packageRoot)
    let filesToInstall = allFiles.filter { shouldInstall($0) }

    // 6. 备份会被覆盖的文件 + 复制（源文件缺失时跳过，避免单个缺失文件卡死整包安装）
    let addedFiles = try applyPackageFiles(
      packageRoot: packageRoot, files: filesToInstall,
      rime: rime, backupDir: backupDir(for: pkg.id), overwrite: false)

    // 7. 启用默认方案
    enableSchema(pkg.defaultSchema, environment: environment)

    // 8. 重新部署
    try SquirrelBridge.deploy(environment: environment)
    try? await Task.sleep(nanoseconds: 2_000_000_000)

    // 9. 写清单（记录 release tag 或 commit SHA，用于后续更新比对）
    let manifest = PackageManifest(
      id: pkg.id,
      addedFiles: addedFiles,
      backupDir: backupDir(for: pkg.id).path(percentEncoded: false),
      defaultSchema: pkg.defaultSchema,
      installedAt: Date(),
      version: "0.3.0",
      installedCommit: commitSHA,
      installedTag: releaseTag)
    let mData = try JSONEncoder().encode(manifest)
    try mData.write(to: manifestURL(for: pkg.id), options: .atomic)

    // 清理临时文件
    try? fm.removeItem(at: stage)
    try? fm.removeItem(at: zipURL)
    return manifest
  }

  // MARK: - 语法模型（万象等）

  /// 下载语法模型单文件（.gram）。release 固定为 LTS tag，不走 latest，
  /// 候选地址优先 CNB 大陆镜像，其次原始 URL 与其镜像。
  private static func downloadGrammarAsset(pkg: DictionaryPackage) async throws -> URL {
    let asset = pkg.releaseAsset ?? "wanxiang-lts-zh-hans.gram"
    let original = pkg.sourceURL
    var candidates: [String] = []
    // CNB 镜像（万象官方大陆镜像，路径固定为 model/）
    let cnb = "https://cnb.cool/amzxyz/rime-wanxiang/-/releases/download/model/\(asset)"
    candidates.append(cnb)
    candidates.append(original)
    candidates.append(contentsOf: GitHubMirrorFetch.candidateURLs(for: original))

    let dest = FileManager.default.temporaryDirectory
      .appending(path: "squirrel-panel-\(UUID().uuidString)-\(asset)")
    var lastURL = original
    for urlString in candidates {
      lastURL = urlString
      do {
        try await GitHubMirrorFetch.download(from: urlString, to: dest, timeout: 120)
        return dest
      } catch {
        continue
      }
    }
    throw PackageManagerError.downloadFailed(lastURL)
  }

  /// 构造语法模型的候选下载地址（CNB 镜像优先，其次原始 URL 与其镜像）。
  private static func grammarCandidateURLs(pkg: DictionaryPackage) -> [String] {
    let asset = pkg.releaseAsset ?? "wanxiang-lts-zh-hans.gram"
    let cnb = "https://cnb.cool/amzxyz/rime-wanxiang/-/releases/download/model/\(asset)"
    return [cnb, pkg.sourceURL] + GitHubMirrorFetch.candidateURLs(for: pkg.sourceURL)
  }

  /// 获取远程 .gram 文件大小（用于「有更新」判定）。全部候选失败返回 nil。
  static func grammarContentLength(pkg: DictionaryPackage) async -> Int? {
    await GitHubMirrorFetch.contentLength(forURLs: grammarCandidateURLs(pkg: pkg))
  }

  /// 在 rime_ice.custom.yaml 的 patch 下写入 grammar/language，启用语法模型。
  /// 语法模型属于方案级配置，放在 default.custom.yaml 不会生效；
  /// 同时清理旧位置（v1.2.3 测试版误写入 default.custom.yaml）的遗留键。
  private static func applyGrammarPatch(language: String) throws {
    let rime = rimeDir()

    // 正确位置：方案级补丁
    let schemaFile = rime.appending(path: "rime_ice.custom.yaml")
    let schemaPatch = CustomYAMLFile(fileURL: schemaFile)
    schemaPatch.load()
    schemaPatch.set(language, forPath: "grammar/language")
    // 启用 octagram 所需的 collocation prism。若目标方案 schema 本身未声明 grammar 段，
    // 此 custom patch 会创建该段，使 octagram 真正加载 wanxiang 模型。
    schemaPatch.set("rime_ice.prism", forPath: "grammar/collocation_prism")
    try schemaPatch.save()

    // 兼容清理：若旧位置有同名键，一并移除
    let defaultFile = rime.appending(path: "default.custom.yaml")
    let defaultPatch = CustomYAMLFile(fileURL: defaultFile)
    defaultPatch.load()
    if defaultPatch.string(forPath: "grammar/language") != nil {
      defaultPatch.set(nil, forPath: "grammar/language")
      try? defaultPatch.save()
    }
  }

  /// 安装语法模型：下载 .gram → 复制到 Rime 目录 → 写 grammar 配置 → 部署 → 写清单
  private static func installGrammar(pkg: DictionaryPackage, environment: RimeEnvironment) async throws -> PackageManifest {
    // 语法模型必须挂载在雾凇（rime_ice）方案上；雾凇未安装则直接拒绝，避免装了不生效。
    guard Self.isRimeIceInstalled() else {
      throw PackageManagerError.grammarRequiresRimeIce
    }

    let fm = FileManager.default
    let rime = rimeDir()
    try fm.createDirectory(at: rime, withIntermediateDirectories: true)
    try fm.createDirectory(at: manifestsDir(), withIntermediateDirectories: true)

    let asset = pkg.releaseAsset ?? "wanxiang-lts-zh-hans.gram"
    let language = pkg.grammarLanguage

    // 安装前先备份「将被修改的文件」：rime_ice.custom.yaml。
    // 即便后续 save() 也会留 .bak，这里显式兜底，确保端用户无需手动修复即可回退。
    let schemaFile = rime.appending(path: "rime_ice.custom.yaml")
    if fm.fileExists(atPath: schemaFile.path(percentEncoded: false)) {
      let bak = schemaFile.appendingPathExtension("bak")
      try? fm.removeItem(at: bak)
      try? fm.copyItem(at: schemaFile, to: bak)
    }

    let fileURL = try await downloadGrammarAsset(pkg: pkg)
    let dst = rime.appending(path: asset)
    try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? fm.removeItem(at: dst)
    try fm.copyItem(at: fileURL, to: dst)

    try applyGrammarPatch(language: language)

    try SquirrelBridge.deploy(environment: environment)
    try? await Task.sleep(nanoseconds: 2_000_000_000)

    let installedSize: Int?
    if let attrs = try? fm.attributesOfItem(atPath: dst.path(percentEncoded: false)),
       let size = attrs[FileAttributeKey.size] as? UInt64 {
      installedSize = Int(size)
    } else {
      installedSize = nil
    }
    let manifest = PackageManifest(
      id: pkg.id,
      addedFiles: [asset],
      backupDir: backupDir(for: pkg.id).path(percentEncoded: false),
      defaultSchema: "",
      installedAt: Date(),
      version: "0.3.0",
      installedCommit: nil,
      installedTag: "LTS",
      installedSize: installedSize)
    let mData = try JSONEncoder().encode(manifest)
    try mData.write(to: manifestURL(for: pkg.id), options: [.atomic])

    try? fm.removeItem(at: fileURL)
    return manifest
  }

  // MARK: - AI 引擎（AIEnergy）

  // MARK: - AI 引擎来源解析辅助

  /// 把单文件从 src 复制到 Rime 目录的 dstRel 位置，按 overwrite 决定是否先备份。
  /// 返回是否成功写入（源文件缺失时返回 false，不中断整体流程）。
  private static func copyEngineFile(src: URL, dstRel: String, rime: URL, backupDir: URL, overwrite: Bool) -> Bool {
    let fm = FileManager.default
    let dst = rime.appending(path: dstRel)
    guard fm.fileExists(atPath: src.path(percentEncoded: false)) else {
      print("[SquirrelPanel] AIEngine skip missing source: \(src.path(percentEncoded: false))")
      return false
    }
    if !overwrite, fm.fileExists(atPath: dst.path(percentEncoded: false)) {
      let backup = backupDir.appending(path: dstRel)
      try? fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? fm.removeItem(at: backup)
      try? fm.copyItem(at: dst, to: backup)
    }
    try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? fm.removeItem(at: dst)
    try? fm.copyItem(at: src, to: dst)
    return true
  }

  /// 解析 AI 引擎来源（设计文档 D2：自研叠加层 + 白知新 bzx/ 内核，不二次封装仓库）。
  ///  - kernelRoot：在线时从白知新仓库（分支归档 `archive/refs/heads/<branch>.zip`，
  ///    恒定可用、无需 latest release）拉取并解包后得到的仓库根；离线时为 nil。
  ///  - overlayRoot：面板内置 `AIEnergyEngine`（构建时拷入 bundle），始终提供自研
  ///    lua 叠加层与我们的服务进程；离线时内核也自此兜底。
  /// 返回三元组 (kernelRoot?, overlayRoot, releaseTag?)。
  private static func resolveAIEngineSource(pkg: DictionaryPackage) async throws -> (kernelRoot: URL?, overlayRoot: URL, releaseTag: String?) {
    var kernelRoot: URL? = nil
    if let branch = pkg.branch, !branch.isEmpty,
       let owner = pkg.repoOwner, let repo = pkg.repoName,
       !owner.isEmpty, !repo.isEmpty {
      let archiveURL = "https://github.com/\(owner)/\(repo)/archive/refs/heads/\(branch).zip"
      let candidates = [archiveURL] + GitHubMirrorFetch.candidateURLs(for: archiveURL)
      let zipDest = FileManager.default.temporaryDirectory
        .appending(path: "squirrel-panel-aiengine-\(UUID().uuidString).zip")
      var downloaded: URL? = nil
      for c in candidates {
        do {
          try await GitHubMirrorFetch.download(from: c, to: zipDest, timeout: 120)
          downloaded = zipDest
          break
        } catch { continue }
      }
      if let zipURL = downloaded {
        let stage = FileManager.default.temporaryDirectory
          .appending(path: "squirrel-panel-aiengine-ext-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: stage)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zipURL.path(percentEncoded: false), stage.path(percentEncoded: false)]
        try ditto.run(); ditto.waitUntilExit()
        try? FileManager.default.removeItem(at: zipURL)
        if ditto.terminationStatus == 0 {
          let root = locatePackageRoot(in: stage)
          // 校验内核确实存在，避免把残缺 zip 当真源
          if FileManager.default.fileExists(atPath: root.appending(path: "bzx/bzx_ai.py").path(percentEncoded: false)) {
            kernelRoot = root
          } else {
            try? FileManager.default.removeItem(at: stage)
          }
        }
      }
    }
    guard let overlayRoot = Bundle.main.url(forResource: "AIEnergyEngine", withExtension: nil),
          FileManager.default.fileExists(atPath: overlayRoot.path(percentEncoded: false)) else {
      throw PackageManagerError.downloadFailed(pkg.sourceURL)
    }
    return (kernelRoot, overlayRoot, pkg.branch)
  }

  /// 收集在线仓库里需要部署的内核相对路径。我们只实际 import `bzx_ai.AIClient`
  ///（见 AIEnergy_service.py），故内核只取 `bzx/bzx_ai.py`，扁平化为 `bzx_ai.py` 部署；
  /// 不部署 `bzx_service.py`（我们用自研 AIEnergy_service.py）、`bzx_config.json`（我们自管配置）、
  /// `bzx_ipc.py`（白知新自有文件 IPC，本服务不走它）。保持最小可信部署面。
  private static func aiEngineKernelRepoRels(in root: URL) -> [String] {
    snapshotFiles(in: root).filter { $0 == "bzx/bzx_ai.py" }
  }

  /// 把内核相对路径扁平化为部署名：bzx/bzx_ai.py -> bzx_ai.py（与内置包布局一致，供 `from bzx_ai import` 命中）。
  private static func aiEngineKernelFlatRel(_ repoRel: String) -> String {
    (repoRel as NSString).lastPathComponent
  }

  /// 安装 AI 引擎（设计文档 D2：自研叠加层 + 白知新 bzx/ 内核，不二次封装）。
  ///  - 自研叠加层（lua/AIEnergy_*.lua、AIEnergy_service.py）始终来自面板内置包；
  ///  - 内核 bzx/ 在线时取自白知新仓库实时拉取，离线时回退到内置 vendored bzx_ai.py。
  /// 内核文件扁平部署（bzx/bzx_ai.py -> bzx_ai.py），与内置包布局一致，供 `from bzx_ai import` 命中。
  private static func installAIEngine(pkg: DictionaryPackage, environment: RimeEnvironment) async throws -> PackageManifest {
    guard environment.isInstalled else { throw PackageManagerError.squirrelNotInstalled }
    let fm = FileManager.default
    let rime = rimeDir()
    let backup = backupDir(for: pkg.id)
    try fm.createDirectory(at: rime, withIntermediateDirectories: true)
    try fm.createDirectory(at: manifestsDir(), withIntermediateDirectories: true)
    try fm.createDirectory(at: backup, withIntermediateDirectories: true)

    let (kernelRoot, overlayRoot, releaseTag) = try await resolveAIEngineSource(pkg: pkg)
    // 记录 main 分支最新 commit，用于后续更新检查（避免 installedCommit 为空导致一直 .unknown）
    let commitSHA = try? await fetchLatestCommit(pkg: pkg).sha

    // 1) 自研叠加层：始终来自内置包（带备份）
    let overlayFiles = snapshotFiles(in: overlayRoot).filter { shouldInstall($0) }
    var addedFiles: [String] = []
    for rel in overlayFiles {
      if copyEngineFile(src: overlayRoot.appending(path: rel), dstRel: rel,
                        rime: rime, backupDir: backup, overwrite: false) {
        addedFiles.append(rel)
      }
    }

    // 2) 内核：在线取仓库 bzx/ 扁平化部署；离线取内置 vendored bzx_ai.py 兜底
    let kernelRepoRels = kernelRoot.map { aiEngineKernelRepoRels(in: $0) } ?? []
    if !kernelRepoRels.isEmpty, let kr = kernelRoot {
      for repoRel in kernelRepoRels {
        let flat = aiEngineKernelFlatRel(repoRel)
        if copyEngineFile(src: kr.appending(path: repoRel), dstRel: flat,
                          rime: rime, backupDir: backup, overwrite: false) {
          addedFiles.append(flat)
        }
      }
      try? fm.removeItem(at: kr)  // 清理解压目录
    } else {
      // 离线兜底：仅内核 bzx_ai.py（其余文件内置包没有，跳过）
      let flat = "bzx_ai.py"
      if copyEngineFile(src: overlayRoot.appending(path: flat), dstRel: flat,
                        rime: rime, backupDir: backup, overwrite: false) {
        addedFiles.append(flat)
      }
    }

    try SquirrelBridge.deploy(environment: environment)
    try? await Task.sleep(nanoseconds: 2_000_000_000)

    let manifest = PackageManifest(
      id: pkg.id,
      addedFiles: addedFiles,
      backupDir: backup.path(percentEncoded: false),
      defaultSchema: "",
      installedAt: Date(),
      version: "1.0.0",
      installedCommit: commitSHA,
      installedTag: releaseTag)
    let mData = try JSONEncoder().encode(manifest)
    try mData.write(to: manifestURL(for: pkg.id), options: .atomic)
    return manifest
  }

  /// 更新 AI 引擎：重新拉取白知新内核 + 内置叠加层，覆盖部署（保留首次安装的原始备份），
  /// 删除「旧版有、新版没有」的文件，清理解压目录。
  private static func updateAIEngine(pkg: DictionaryPackage, environment: RimeEnvironment) async throws -> PackageManifest {
    let mURL = manifestURL(for: pkg.id)
    guard let data = try? Data(contentsOf: mURL),
          let manifest = try? JSONDecoder().decode(PackageManifest.self, from: data) else {
      throw PackageManagerError.notManagedByPanel
    }
    guard environment.isInstalled else { throw PackageManagerError.squirrelNotInstalled }

    let fm = FileManager.default
    let rime = rimeDir()
    let backup = URL(fileURLWithPath: manifest.backupDir)
    try fm.createDirectory(at: rime, withIntermediateDirectories: true)

    let (kernelRoot, overlayRoot, releaseTag) = try await resolveAIEngineSource(pkg: pkg)
    // 更新 main 分支最新 commit，使更新检查能正确比对
    let commitSHA = try? await fetchLatestCommit(pkg: pkg).sha

    // 收集新版应部署的全部相对路径（叠加层 + 内核扁平名）
    var newRels: [String] = []
    newRels.append(contentsOf: snapshotFiles(in: overlayRoot).filter { shouldInstall($0) })
    let kernelRepoRels = kernelRoot.map { aiEngineKernelRepoRels(in: $0) } ?? []
    if !kernelRepoRels.isEmpty {
      newRels.append(contentsOf: kernelRepoRels.map { aiEngineKernelFlatRel($0) })
    } else {
      newRels.append("bzx_ai.py")
    }
    let newSet = Set(newRels)

    // 删除「旧版有、新版没有」的文件（仅动我们追踪的）
    for rel in manifest.addedFiles where !newSet.contains(rel) {
      try? fm.removeItem(at: rime.appending(path: rel))
    }

    // 覆盖部署叠加层
    let overlayFiles = snapshotFiles(in: overlayRoot).filter { shouldInstall($0) }
    for rel in overlayFiles {
      _ = copyEngineFile(src: overlayRoot.appending(path: rel), dstRel: rel,
                         rime: rime, backupDir: backup, overwrite: true)
    }
    // 覆盖部署内核
    if let kr = kernelRoot, !kernelRepoRels.isEmpty {
      for repoRel in kernelRepoRels {
        let flat = aiEngineKernelFlatRel(repoRel)
        _ = copyEngineFile(src: kr.appending(path: repoRel), dstRel: flat,
                           rime: rime, backupDir: backup, overwrite: true)
      }
      try? fm.removeItem(at: kr)
    } else {
      _ = copyEngineFile(src: overlayRoot.appending(path: "bzx_ai.py"), dstRel: "bzx_ai.py",
                         rime: rime, backupDir: backup, overwrite: true)
    }

    try SquirrelBridge.deploy(environment: environment)
    try? await Task.sleep(nanoseconds: 2_000_000_000)

    var updated = manifest
    updated.addedFiles = newRels
    updated.installedCommit = commitSHA
    updated.installedTag = releaseTag
    updated.installedAt = Date()
    updated.version = "1.0.1"
    let mData = try JSONEncoder().encode(updated)
    try mData.write(to: mURL, options: .atomic)
    return updated
  }

  /// 卸载 AI 引擎：删除本面板新增的文件，还原被覆盖的原始文件，清理清单。
  private static func uninstallAIEngine(pkg: DictionaryPackage, environment: RimeEnvironment) async throws {
    let mURL = manifestURL(for: pkg.id)
    guard let data = try? Data(contentsOf: mURL),
          let manifest = try? JSONDecoder().decode(PackageManifest.self, from: data) else {
      throw PackageManagerError.notManagedByPanel
    }
    let fm = FileManager.default
    let rime = rimeDir()
    let backupBase = URL(fileURLWithPath: manifest.backupDir)

    for rel in manifest.addedFiles {
      let dst = rime.appending(path: rel)
      if fm.fileExists(atPath: dst.path(percentEncoded: false)) { try? fm.removeItem(at: dst) }
    }
    for rel in manifest.addedFiles {
      let backup = backupBase.appending(path: rel)
      let dst = rime.appending(path: rel)
      if fm.fileExists(atPath: backup.path(percentEncoded: false)) {
        try? fm.removeItem(at: dst)
        try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.copyItem(at: backup, to: dst)
      }
    }

    try SquirrelBridge.deploy(environment: environment)
    try? await Task.sleep(nanoseconds: 2_000_000_000)
    try? fm.removeItem(at: mURL)
  }

  /// 更新语法模型：重新下载 .gram（覆盖）→ 幂等重应用 grammar 配置 → 部署 → 更新清单
  private static func updateGrammar(pkg: DictionaryPackage, environment: RimeEnvironment) async throws -> PackageManifest {
    let fm = FileManager.default
    let rime = rimeDir()
    let asset = pkg.releaseAsset ?? "wanxiang-lts-zh-hans.gram"
    let language = pkg.grammarLanguage

    let fileURL = try await downloadGrammarAsset(pkg: pkg)
    let dst = rime.appending(path: asset)
    try? fm.removeItem(at: dst)
    try fm.copyItem(at: fileURL, to: dst)
    try applyGrammarPatch(language: language)

    try SquirrelBridge.deploy(environment: environment)
    try? await Task.sleep(nanoseconds: 2_000_000_000)

    let mURL = manifestURL(for: pkg.id)
    guard let data = try? Data(contentsOf: mURL),
          var manifest = try? JSONDecoder().decode(PackageManifest.self, from: data) else {
      throw PackageManagerError.notManagedByPanel
    }
    manifest.installedAt = Date()
    if let attrs = try? fm.attributesOfItem(atPath: dst.path(percentEncoded: false)),
       let size = attrs[FileAttributeKey.size] as? UInt64 {
      manifest.installedSize = Int(size)
    }
    let mData = try JSONEncoder().encode(manifest)
    try mData.write(to: mURL, options: [.atomic])

    try? fm.removeItem(at: fileURL)
    return manifest
  }

  /// 卸载语法模型：删除 .gram 文件 → 回退 grammar 配置 → 部署 → 删除清单
  private static func uninstallGrammar(pkg: DictionaryPackage, environment: RimeEnvironment) async throws {
    let fm = FileManager.default
    let rime = rimeDir()
    let mURL = manifestURL(for: pkg.id)
    guard let data = try? Data(contentsOf: mURL),
          let manifest = try? JSONDecoder().decode(PackageManifest.self, from: data) else {
      throw PackageManagerError.notManagedByPanel
    }

    for rel in manifest.addedFiles {
      let dst = rime.appending(path: rel)
      try? fm.removeItem(at: dst)
    }

    // 移除方案级配置（grammar/language 与 grammar/collocation_prism 一并清掉，避免残留）
    let schemaPatch = CustomYAMLFile(fileURL: rime.appending(path: "rime_ice.custom.yaml"))
    schemaPatch.load()
    schemaPatch.removeGrammar()
    try? schemaPatch.save()

    // 兼容清理旧位置
    let defaultPatch = CustomYAMLFile(fileURL: rime.appending(path: "default.custom.yaml"))
    defaultPatch.load()
    defaultPatch.removeGrammar()
    try? defaultPatch.save()

    try SquirrelBridge.deploy(environment: environment)
    try? await Task.sleep(nanoseconds: 2_000_000_000)

    try? fm.removeItem(at: mURL)
  }

  // MARK: - 更新

  /// 把包内文件复制进 Rime 目录。overwrite=true 时直接覆盖（用于更新，保留首次安装时的原始备份）；
  /// overwrite=false 时会先备份被覆盖的文件（用于首次安装）。返回实际写入的相对路径列表。
  /// 若 source 文件在包内不存在（zip 损坏/不完整），则跳过并记录警告，不终止整个流程。
  private static func applyPackageFiles(
    packageRoot: URL, files: [String], rime: URL,
    backupDir: URL, overwrite: Bool
  ) throws -> [String] {
    let fm = FileManager.default
    var written: [String] = []
    for rel in files {
      let src = packageRoot.appending(path: rel)
      let dst = rime.appending(path: rel)
      guard fm.fileExists(atPath: src.path(percentEncoded: false)) else {
        print("[SquirrelPanel] update skipped missing source file: \(src.path(percentEncoded: false))")
        continue
      }
      if !overwrite, fm.fileExists(atPath: dst.path(percentEncoded: false)) {
        let backup = backupDir.appending(path: rel)
        try? fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: backup)
        try? fm.copyItem(at: dst, to: backup)
      }
      try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? fm.removeItem(at: dst)
      try fm.copyItem(at: src, to: dst)
      written.append(rel)
    }
    return written
  }

  /// 拉取上游仓库指定分支的最新 commit（用于更新比对），自动 fallback 到 GitHub 镜像。
  /// 若用户配置了 GitHub Token，则在所有公开镜像失败时携带 Token 直连 GitHub API 兜底。
  static func fetchLatestCommit(pkg: DictionaryPackage) async throws -> (sha: String, date: Date?) {
    guard let owner = pkg.repoOwner, let repo = pkg.repoName, let branch = pkg.branch,
          !owner.isEmpty, !repo.isEmpty, !branch.isEmpty else {
      throw PackageManagerError.updateCheckFailed("no repo info")
    }
    let token = UserDefaults.standard.string(forKey: "AI.githubToken")?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    do {
      let result = try await GitHubMirrorFetch.fetchLatestCommit(owner: owner, repo: repo, branch: branch)
      return (result.sha, result.date)
    } catch {
      if !token.isEmpty {
        if let pair = try? await fetchLatestCommitDirectViaToken(owner: owner, repo: repo, branch: branch, token: token) {
          return pair
        }
      }
      throw error
    }
  }

  private static func fetchLatestCommitDirectViaToken(owner: String, repo: String, branch: String, token: String) async throws -> (sha: String, date: Date?) {
    let api = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/commits?sha=\(branch)&per_page=1")!
    var req = URLRequest(url: api, timeoutInterval: 12)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    req.setValue("Squirrel-Panel/1.0.0", forHTTPHeaderField: "User-Agent")
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      throw NSError(domain: "GitHubAPI", code: code)
    }
    guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
          let first = arr.first,
          let sha = first["sha"] as? String else {
      throw NSError(domain: "GitHubAPI", code: -1)
    }
    var date: Date? = nil
    if let commit = first["commit"] as? [String: Any],
       let author = commit["author"] as? [String: Any],
       let dateStr = author["date"] as? String {
      date = ISO8601DateFormatter().date(from: dateStr)
    }
    return (sha, date)
  }

  /// 更新已安装的包到上游最新版本。保留首次安装时生成的原始备份（卸载时还原用）。
  static func update(pkg: DictionaryPackage, environment: RimeEnvironment) async throws -> PackageManifest {
    let mURL = manifestURL(for: pkg.id)
    guard let data = try? Data(contentsOf: mURL),
          let manifest = try? JSONDecoder().decode(PackageManifest.self, from: data) else {
      throw PackageManagerError.notManagedByPanel
    }
    guard environment.isInstalled else { throw PackageManagerError.squirrelNotInstalled }

    // 语法模型（万象等）：重新下载 .gram 文件 + 幂等重应用 grammar 配置
    if pkg.isGrammar {
      return try await updateGrammar(pkg: pkg, environment: environment)
    }

    // AI 引擎：重新部署 lua + 服务到 Rime 目录
    if pkg.isAIEngine {
      return try await updateAIEngine(pkg: pkg, environment: environment)
    }

    let fm = FileManager.default
    let rime = rimeDir()
    try fm.createDirectory(at: rime, withIntermediateDirectories: true)

    let releaseTag: String?
    let commitSHA: String?
    if usesReleaseAsset(pkg) {
      releaseTag = try? await fetchLatestRelease(pkg: pkg).tag
      commitSHA = nil
    } else {
      releaseTag = nil
      commitSHA = try? await fetchLatestCommit(pkg: pkg).sha
    }

    // 1. 下载：release asset 包使用 release asset 候选 URL；commit-based 包使用精确 commit 归档
    let zipURL = try await download(from: installDownloadURLs(for: pkg, releaseTag: releaseTag, commitSHA: commitSHA))

    // 2. 解压
    let stage = FileManager.default.temporaryDirectory
      .appending(path: "squirrel-panel-update-\(pkg.id)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? fm.removeItem(at: stage)
    try fm.createDirectory(at: stage, withIntermediateDirectories: true)
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-x", "-k", zipURL.path(percentEncoded: false), stage.path(percentEncoded: false)]
    try ditto.run()
    ditto.waitUntilExit()
    guard ditto.terminationStatus == 0 else {
      throw PackageManagerError.extractFailed("ditto exit \(ditto.terminationStatus)")
    }

    // 3. 定位包根
    let packageRoot = locatePackageRoot(in: stage)

    // 4. 枚举要安装的文件（排除非运行时文件与 macOS 元数据）
    let allFiles = snapshotFiles(in: packageRoot)
    let filesToInstall = allFiles.filter { shouldInstall($0) }

    // 5. 删除「旧版本有、新版本没有」的文件（仅动我们追踪的）
    let oldSet = Set(manifest.addedFiles)
    let newSet = Set(filesToInstall)
    for rel in oldSet where !newSet.contains(rel) {
      let dst = rime.appending(path: rel)
      try? fm.removeItem(at: dst)
    }

    // 6. 覆盖写入（保留首次安装时的原始备份）
    _ = try applyPackageFiles(
      packageRoot: packageRoot, files: filesToInstall,
      rime: rime, backupDir: URL(fileURLWithPath: manifest.backupDir), overwrite: true)

    // 7. 启用默认方案 + 重新部署
    enableSchema(pkg.defaultSchema, environment: environment)
    try SquirrelBridge.deploy(environment: environment)
    try? await Task.sleep(nanoseconds: 2_000_000_000)

    // 8. 更新清单
    var updated = manifest
    updated.addedFiles = filesToInstall
    updated.installedCommit = commitSHA
    updated.installedTag = releaseTag
    updated.installedAt = Date()
    updated.version = "0.3.2"
    let mData = try JSONEncoder().encode(updated)
    try mData.write(to: mURL, options: .atomic)

    // 清理
    try? fm.removeItem(at: stage)
    try? fm.removeItem(at: zipURL)
    return updated
  }

  // MARK: - 卸载

  static func uninstall(pkg: DictionaryPackage, environment: RimeEnvironment) async throws {
    let mURL = manifestURL(for: pkg.id)
    guard let data = try? Data(contentsOf: mURL),
          let manifest = try? JSONDecoder().decode(PackageManifest.self, from: data) else {
      throw PackageManagerError.notManagedByPanel
    }
    // 雾凇拼音（rime_ice）作为万象语法模型的挂载点与配置载体：
    // 若万象仍安装就卸载雾凇，会导致 rime_ice.custom.yaml 与 .gram 注入脱节，模型残留失效。
    // 因此强制要求先卸载万象语法模型，再卸载雾凇拼音。
    if pkg.id == "rime-ice" {
      guard !isPackageInstalled(id: "wanxiang-grammar", environment: environment) else {
        throw PackageManagerError.grammarMustBeUninstalledFirst
      }
    }
    // 语法模型（万象等）：移除 .gram 文件 + 回退 grammar 配置，走独立分支
    if pkg.isGrammar {
      return try await uninstallGrammar(pkg: pkg, environment: environment)
    }

    // AI 引擎：移除 lua + 服务文件并还原备份，走独立分支
    if pkg.isAIEngine {
      return try await uninstallAIEngine(pkg: pkg, environment: environment)
    }
    let fm = FileManager.default
    let rime = rimeDir()
    let backupBase = URL(fileURLWithPath: manifest.backupDir)

    // 1. 删除本面板新增的文件
    for rel in manifest.addedFiles {
      let dst = rime.appending(path: rel)
      if fm.fileExists(atPath: dst.path(percentEncoded: false)) {
        try? fm.removeItem(at: dst)
      }
    }

    // 2. 还原被覆盖的原始文件
    for rel in manifest.addedFiles {
      let backup = backupBase.appending(path: rel)
      let dst = rime.appending(path: rel)
      if fm.fileExists(atPath: backup.path(percentEncoded: false)) {
        try? fm.removeItem(at: dst)
        try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.copyItem(at: backup, to: dst)
      }
    }

    // 3. 从 schema_list 移除该默认方案（但不允许列表变空）
    disableSchema(pkg.defaultSchema, environment: environment)

    // 4. 重新部署
    try SquirrelBridge.deploy(environment: environment)
    try? await Task.sleep(nanoseconds: 2_000_000_000)

    // 5. 删除清单
    try? fm.removeItem(at: mURL)
  }

  // MARK: - 方案启用辅助

  private static func enableSchema(_ id: String, environment: RimeEnvironment) {
    // 仅当该方案的 schema 文件确实存在时才加入启用列表，避免写入不存在的方案 id
    let schemaFile = rimeDir().appending(path: "\(id).schema.yaml")
    guard FileManager.default.fileExists(atPath: schemaFile.path(percentEncoded: false)) else { return }
    let fileURL = rimeDir().appending(path: "default.custom.yaml")
    let patch = CustomYAMLFile(fileURL: fileURL)
    patch.load()
    var ids = SchemaCatalog.enabledSchemaIDs(patch: patch, environment: environment)
    if !ids.contains(id) {
      ids.insert(id, at: 0)
      SchemaCatalog.setEnabledSchemas(ids, patch: patch)
      try? patch.save()
    }
  }

  private static func disableSchema(_ id: String, environment: RimeEnvironment) {
    let fileURL = rimeDir().appending(path: "default.custom.yaml")
    let patch = CustomYAMLFile(fileURL: fileURL)
    patch.load()
    var ids = SchemaCatalog.enabledSchemaIDs(patch: patch, environment: environment)
    if let idx = ids.firstIndex(of: id) {
      ids.remove(at: idx)
      // 不允许方案列表变空，否则输入法将彻底打不出字
      if ids.isEmpty { ids = [id] }
      SchemaCatalog.setEnabledSchemas(ids, patch: patch)
      try? patch.save()
    }
  }

  // MARK: - 下载

  /// 从候选 URL 列表中依次尝试下载，任一成功即返回本地临时文件路径。
  private static func download(from candidates: [String]) async throws -> URL {
    let dest = FileManager.default.temporaryDirectory
      .appending(path: "squirrel-panel-\(UUID().uuidString).zip")
    var lastURL = candidates.first ?? ""
    for urlString in candidates {
      lastURL = urlString
      do {
        try await GitHubMirrorFetch.download(from: urlString, to: dest, timeout: 60)
        return dest
      } catch {
        continue
      }
    }
    throw PackageManagerError.downloadFailed(lastURL)
  }

  /// 该包是否使用 GitHub Release asset 分发（如 full.zip）。
  private static func usesReleaseAsset(_ pkg: DictionaryPackage) -> Bool {
    return pkg.releaseAsset?.isEmpty == false
  }

  /// release asset 包的候选下载 URL：原始 URL + 南大镜像 + 普通镜像前缀。
  private static func releaseAssetURLs(for pkg: DictionaryPackage) -> [String] {
    guard let asset = pkg.releaseAsset, !asset.isEmpty,
          let owner = pkg.repoOwner, !owner.isEmpty,
          let repo = pkg.repoName, !repo.isEmpty else { return [] }
    let original = "https://github.com/\(owner)/\(repo)/releases/latest/download/\(asset)"
    var result = GitHubMirrorFetch.candidateURLs(for: original)
    // 南大镜像使用固定路径结构，不是简单前缀拼接
    let nju = "https://mirror.nju.edu.cn/github-release/\(owner)/\(repo)/LatestRelease/\(asset)"
    result.insert(nju, at: 1)
    return result
  }

  /// 根据包类型构造安装/更新时的候选下载 URL 列表。
  /// - release asset 包：使用 release asset 候选列表。
  /// - commit-based 包：使用精确到 commit 的归档 URL + 普通镜像 fallback。
  private static func installDownloadURLs(
    for pkg: DictionaryPackage,
    releaseTag: String?,
    commitSHA: String?
  ) -> [String] {
    if usesReleaseAsset(pkg) {
      return releaseAssetURLs(for: pkg)
    }
    guard let sha = commitSHA, !sha.isEmpty,
          let owner = pkg.repoOwner, !owner.isEmpty,
          let repo = pkg.repoName, !repo.isEmpty else {
      return [pkg.sourceURL]
    }
    let original = "https://github.com/\(owner)/\(repo)/archive/\(sha).zip"
    return GitHubMirrorFetch.candidateURLs(for: original)
  }

  /// 获取 release asset 包的 latest release tag（用于版本比对与记录）。
  /// 若用户配置了 GitHub Token，则在所有公开镜像失败时携带 Token 直连 GitHub API 兜底。
  static func fetchLatestRelease(pkg: DictionaryPackage) async throws -> (tag: String, htmlURL: String?) {
    guard let owner = pkg.repoOwner, let repo = pkg.repoName,
          !owner.isEmpty, !repo.isEmpty else {
      throw PackageManagerError.updateCheckFailed("no repo info")
    }
    let repoPath = "\(owner)/\(repo)"
    let token = UserDefaults.standard.string(forKey: "AI.githubToken")?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    do {
      let result = try await GitHubMirrorFetch.fetchLatestRelease(repo: repoPath)
      return (result.tag, result.htmlURL)
    } catch {
      if !token.isEmpty {
        // 公开镜像全部失败 + 配置了 Token → 携带 Token 直连 GitHub API
        if let (tag, html) = try? await fetchLatestReleaseDirectViaToken(repoPath: repoPath, token: token) {
          return (tag, html)
        }
      }
      throw error
    }
  }

  /// 带 Token 直连 GitHub API 解析最新 release tag
  private static func fetchLatestReleaseDirectViaToken(repoPath: String, token: String) async throws -> (tag: String, htmlURL: String?) {
    let api = URL(string: "https://api.github.com/repos/\(repoPath)/releases/latest")!
    var req = URLRequest(url: api, timeoutInterval: 12)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    req.setValue("Squirrel-Panel/1.0.0", forHTTPHeaderField: "User-Agent")
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      throw NSError(domain: "GitHubAPI", code: code)
    }
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tag = obj["tag_name"] as? String else {
      throw NSError(domain: "GitHubAPI", code: -1)
    }
    let htmlURL = obj["html_url"] as? String
    return (tag, htmlURL)
  }

  // MARK: - 定位包根

  private static func locatePackageRoot(in stage: URL) -> URL {
    guard let items = try? FileManager.default.contentsOfDirectory(
      at: stage, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
      return stage
    }
    let dirs = items.filter { $0.hasDirectoryPath }
    if dirs.count == 1 {
      return dirs[0]
    }
    return stage
  }
}
