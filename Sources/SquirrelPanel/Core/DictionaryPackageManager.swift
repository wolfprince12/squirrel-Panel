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
  let defaultSchema: String
  let homepage: String
  let author: String
}

struct PackageManifest: Codable {
  var id: String
  var addedFiles: [String]          // 相对 Rime 目录的相对路径
  var backupDir: String             // 备份目录的绝对路径
  var defaultSchema: String
  var installedAt: Date
  var version: String
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
  case commandFailed(String, Int32)

  var errorDescription: String? {
    switch self {
    case .downloadFailed(let u): return String(format: String(localized: "package.error.download"), u)
    case .extractFailed(let m): return String(format: String(localized: "package.error.extract"), m)
    case .notManagedByPanel: return String(localized: "package.error.notManaged")
    case .squirrelNotInstalled: return String(localized: "error.squirrelNotInstalled")
    case .commandFailed(let c, let code): return String(format: String(localized: "error.commandFailed"), c, code)
    }
  }
}

enum DictionaryPackageManager {

  static let managedDirName = ".squirrel-panel"
  /// 安装时跳过的非运行时文件/目录（陈旧编译产物、仓库元数据、庞杂素材等）
  static let excludeFromInstall = Set([
    "build", ".git", ".github", "others",
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
  private static func snapshotFiles(in root: URL) -> [String] {
    var result: [String] = []
    guard let enumerator = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return result }
    for case let url as URL in enumerator {
      if url.hasDirectoryPath { continue }
      let base = root.path(percentEncoded: false)
      let rel = url.path(percentEncoded: false).replacingOccurrences(of: base, with: "")
      let clean = rel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      if !clean.isEmpty { result.append(clean) }
    }
    return result
  }

  // MARK: - 安装

  static func install(pkg: DictionaryPackage, environment: RimeEnvironment) async throws -> PackageManifest {
    guard environment.isInstalled else { throw PackageManagerError.squirrelNotInstalled }

    let fm = FileManager.default
    let rime = rimeDir()
    try fm.createDirectory(at: rime, withIntermediateDirectories: true)
    try fm.createDirectory(at: manifestsDir(), withIntermediateDirectories: true)
    try fm.createDirectory(at: backupDir(for: pkg.id), withIntermediateDirectories: true)

    // 1. 下载
    let zipURL = try await download(from: pkg.sourceURL)

    // 2. 解压到临时目录（ditto 非交互，可正确处理非常规文件名）
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

    // 3. 定位包根（处理内层文件夹，如 rime-ice-main）
    let packageRoot = locatePackageRoot(in: stage)

    // 4. 枚举要安装的文件（排除非运行时文件）
    let allFiles = snapshotFiles(in: packageRoot)
    let filesToInstall = allFiles.filter { rel in
      let top = rel.split(separator: "/").first.map(String.init) ?? rel
      return !Self.excludeFromInstall.contains(top)
    }

    // 5. 备份会被覆盖的文件 + 复制
    var addedFiles: [String] = []
    for rel in filesToInstall {
      let src = packageRoot.appending(path: rel)
      let dst = rime.appending(path: rel)
      if fm.fileExists(atPath: dst.path(percentEncoded: false)) {
        let backup = backupDir(for: pkg.id).appending(path: rel)
        try? fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: backup)
        try? fm.copyItem(at: dst, to: backup)
      }
      try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? fm.removeItem(at: dst)
      try fm.copyItem(at: src, to: dst)
      addedFiles.append(rel)
    }

    // 6. 启用默认方案
    enableSchema(pkg.defaultSchema, environment: environment)

    // 7. 重新部署
    try SquirrelBridge.deploy(environment: environment)
    try? await Task.sleep(nanoseconds: 2_000_000_000)

    // 8. 写清单
    let manifest = PackageManifest(
      id: pkg.id,
      addedFiles: addedFiles,
      backupDir: backupDir(for: pkg.id).path(percentEncoded: false),
      defaultSchema: pkg.defaultSchema,
      installedAt: Date(),
      version: "0.3.0")
    let mData = try JSONEncoder().encode(manifest)
    try mData.write(to: manifestURL(for: pkg.id), options: .atomic)

    // 清理临时文件
    try? fm.removeItem(at: stage)
    try? fm.removeItem(at: zipURL)
    return manifest
  }

  // MARK: - 卸载

  static func uninstall(pkg: DictionaryPackage, environment: RimeEnvironment) async throws {
    let mURL = manifestURL(for: pkg.id)
    guard let data = try? Data(contentsOf: mURL),
          let manifest = try? JSONDecoder().decode(PackageManifest.self, from: data) else {
      throw PackageManagerError.notManagedByPanel
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

  private static func download(from urlString: String) async throws -> URL {
    guard let url = URL(string: urlString) else { throw PackageManagerError.downloadFailed(urlString) }
    let dest = FileManager.default.temporaryDirectory
      .appending(path: "squirrel-panel-\(UUID().uuidString).zip")
    do {
      let (data, _) = try await URLSession.shared.data(from: url)
      guard !data.isEmpty else { throw PackageManagerError.downloadFailed(urlString) }
      try data.write(to: dest, options: .atomic)
    } catch {
      throw PackageManagerError.downloadFailed(urlString)
    }
    return dest
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
