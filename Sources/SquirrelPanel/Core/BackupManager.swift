//
//  BackupManager.swift
//  Squirrel Panel
//
//  配置快照备份 / 恢复 / 对比。
//
//  设计目标：只备份用户**可编辑的配置文件**（yaml 配置、*.custom.yaml 覆盖、
//  AI 引擎配置 json/lua 等），写入 ~/Library/Rime/backups/<时间戳>/，并写
//  manifest.json 记录元信息。刻意**排除**安装自带 / 大体积产物（mlx 模型、语法模型、
//  系统词典、build 目录、安装文件等），避免每次备份膨胀到 1GB+。
//  支持整量恢复、按文件部分恢复、以及单文件行级 diff 预览。
//

import Foundation

/// 一次备份的元信息
struct BackupInfo: Identifiable {
  var id: String { dirName }
  let dirName: String
  let createdAt: Date
  let label: String?
  let fileCount: Int
  let sizeBytes: Int64

  var sizeText: String {
    ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
  }

  var createdText: String {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    f.locale = Locale(identifier: "zh_CN")
    return f.string(from: createdAt)
  }

  var labelText: String {
    label.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "backup.label.auto")
  }
}

/// 行级差异的一行（unified / 单列格式）
struct DiffLine: Identifiable {
  let id = UUID()
  let text: String
  let kind: DiffKind
}

/// 左右双栏 diff 的一行
struct SideBySideLine: Identifiable {
  let id = UUID()
  let leftNo: Int?    // 备份版行号（nil = 该行为空/新增行）
  let rightNo: Int?   // 当前版行号（nil = 该行为空/删除行）
  let leftText: String
  let rightText: String
  let kind: DiffKind
}

enum DiffKind {
  case added   // 当前版本新增
  case removed // 备份版本存在、当前缺失
  case equal
}

enum BackupError: LocalizedError {
  case failed(String)
  var errorDescription: String? {
    switch self { case .failed(let m): return m }
  }
}

final class BackupManager {

  /// 备份根目录（位于用户目录内，但创建/恢复时会自我排除）
  static let backupsDir: URL = RimeEnvironment.userDirectory.appending(path: "backups")

  // MARK: - 创建 / 列表

  /// 创建一次「配置文件」快照。只备份用户可编辑配置，排除安装产物与大体积数据：
  /// aienergy（mlx 模型）、*.gram 语法模型、cn_dicts/en_dicts/opencc（词典）、build、
  /// *.userdb（词库）、*.dict.yaml / *.schema.yaml（词库与方案定义）、*.bak、__pycache__ 等。
  /// - Parameter label: 备份标签，nil 表示自动备份。
  @discardableResult
  static func createBackup(label: String? = nil) throws -> BackupInfo {
    try ensureDir()
    let fm = FileManager.default
    let dirName = timestamp()
    let dest = backupsDir.appending(path: dirName)
    try fm.createDirectory(at: dest, withIntermediateDirectories: true)

    let src = RimeEnvironment.userDirectory
    var count = 0
    var size: Int64 = 0
    if let enumerator = fm.enumerator(at: src, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
      for case let file as URL in enumerator {
        let rel = file.path(percentEncoded: false)
          .replacingOccurrences(of: src.path(percentEncoded: false), with: "")
          .droppingLeadingSlash
        guard !shouldExclude(rel) else { continue }
        let destFile = dest.appendingPathComponent(rel)
        do {
          try fm.createDirectory(at: destFile.deletingLastPathComponent(), withIntermediateDirectories: true)
          try fm.copyItem(at: file, to: destFile)
          count += 1
          size += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        } catch {
          // 单文件失败不阻断整次备份：可能是 broken symlink / librime 临时持有的
          // LOCK / 权限不足等。跳过该文件，备份继续。
          continue
        }
      }
    }

    let manifest: [String: Any] = [
      "createdAt": ISO8601DateFormatter().string(from: Date()),
      "label": label ?? "",
      "fileCount": count
    ]
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
    try data.write(to: dest.appending(path: "manifest.json"))
    return BackupInfo(dirName: dirName, createdAt: Date(), label: label, fileCount: count, sizeBytes: size)
  }

  /// 列出全部备份（按时间倒序）
  static func listBackups() -> [BackupInfo] {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(
      at: backupsDir,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]) else { return [] }
    return items.filter { $0.hasDirectoryPath }.compactMap { url -> BackupInfo? in
      guard let manifest = loadManifest(url) else { return nil }
      let createdAt = ISO8601DateFormatter().date(from: manifest["createdAt"] as? String ?? "")
        ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        ?? Date()
      let rawLabel = manifest["label"] as? String
      let label = rawLabel.flatMap { $0.isEmpty ? nil : $0 }
      let fileCount = manifest["fileCount"] as? Int ?? 0
      return BackupInfo(dirName: url.lastPathComponent, createdAt: createdAt, label: label,
                        fileCount: fileCount, sizeBytes: directorySize(url))
    }
    .sorted { $0.createdAt > $1.createdAt }
  }

  // MARK: - 恢复 / 删除

  /// 恢复备份。files 为 nil 表示整量恢复，否则只恢复指定相对路径的文件。
  static func restoreBackup(dirName: String, files: [String]? = nil) throws {
    let src = backupsDir.appending(path: dirName)
    let dest = RimeEnvironment.userDirectory
    let fm = FileManager.default
    if let files {
      for rel in files {
        let from = src.appendingPathComponent(rel)
        let to = dest.appendingPathComponent(rel)
        guard fm.fileExists(atPath: from.path(percentEncoded: false)) else { continue }
        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: to)
        try fm.copyItem(at: from, to: to)
      }
    } else {
      guard let enumerator = fm.enumerator(at: src, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
      for case let file as URL in enumerator {
        let rel = file.path(percentEncoded: false)
          .replacingOccurrences(of: src.path(percentEncoded: false), with: "")
          .droppingLeadingSlash
        if rel == "manifest.json" || rel.isEmpty { continue }
        let to = dest.appendingPathComponent(rel)
        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: to)
        try fm.copyItem(at: file, to: to)
      }
    }
  }

  static func deleteBackup(dirName: String) throws {
    try FileManager.default.removeItem(at: backupsDir.appending(path: dirName))
  }

  /// 列出某次备份内可被单文件对比的配置文件（顶层 *.yaml / *.txt / installation.yaml 等）
  static func listBackupFiles(dirName: String) -> [String] {
    let src = backupsDir.appending(path: dirName)
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
    return items
      .filter { !$0.hasDirectoryPath && $0.lastPathComponent != "manifest.json" }
      .map { $0.lastPathComponent }
      .sorted()
  }

  /// 对某个文件做行级 diff：返回合并后的差异序列（备份版 vs 当前版）。
  static func compareBackup(dirName: String, fileName: String) -> [DiffLine] {
    let backupURL = backupsDir.appending(path: dirName).appendingPathComponent(fileName)
    let currentURL = RimeEnvironment.userDirectory.appendingPathComponent(fileName)
    let backupText = (try? String(contentsOf: backupURL, encoding: .utf8)) ?? ""
    let currentText = (try? String(contentsOf: currentURL, encoding: .utf8)) ?? ""
    let a = backupText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let b = currentText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    return diffLines(a, b)
  }

  /// 对某个文件做左右双栏 diff（备份版左栏 / 当前版右栏）。
  static func compareBackupSideBySide(dirName: String, fileName: String) -> (lines: [SideBySideLine], identical: Bool) {
    let backupURL = backupsDir.appending(path: dirName).appendingPathComponent(fileName)
    let currentURL = RimeEnvironment.userDirectory.appendingPathComponent(fileName)
    let backupText = (try? String(contentsOf: backupURL, encoding: .utf8)) ?? ""
    let currentText = (try? String(contentsOf: currentURL, encoding: .utf8)) ?? ""
    let a = backupText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let b = currentText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let lines = diffLinesSideBySide(a, b)
    let identical = lines.allSatisfy { $0.kind == .equal }
    return (lines, identical)
  }

  // MARK: - 内部

  private static func ensureDir() throws {
    try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
  }

  /// 复制目录路径时去掉开头的 "/"，得到相对路径
  ///
  /// 只保留用户可编辑的配置文件，排除安装自带 / 大体积产物：
  /// - aienergy：AI 引擎的 mlx 模型与运行时数据（可达 1.4GB+）
  /// - *.gram：语法模型（可达数百 MB）
  /// - cn_dicts / en_dicts / opencc：系统词典与字符转换表（安装自带）
  /// - build：Rime 编译产物
  /// - *.userdb：librime 运行时学习词库（非用户可编辑配置，且 LOCK 会被 librime 持有）
  /// - *.dict.yaml / *.schema.yaml：词库与方案定义（安装自带，体积大）
  /// - *.bak、__pycache__、backups、.restore_temp：备份自身与缓存
  private static func shouldExclude(_ rel: String) -> Bool {
    let comps = rel.split(separator: "/").map(String.init)
    let lower = rel.lowercased()
    if comps.contains("backups") { return true }
    if comps.contains("build") { return true }
    if comps.contains("aienergy") { return true }
    if comps.contains("cn_dicts") { return true }
    if comps.contains("en_dicts") { return true }
    if comps.contains("opencc") { return true }
    if comps.contains("__pycache__") { return true }
    if comps.contains(where: { $0.hasPrefix(".restore_temp") }) { return true }
    if rel.hasSuffix(".bak") { return true }
    if lower.hasSuffix(".gram") { return true }
    if lower.hasSuffix(".userdb") { return true }
    if lower.hasSuffix(".dict.yaml") || lower.hasSuffix(".schema.yaml") { return true }
    return false
  }

  private static func loadManifest(_ dir: URL) -> [String: Any]? {
    let url = dir.appending(path: "manifest.json")
    guard let data = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return obj
  }

  private static func directorySize(_ url: URL) -> Int64 {
    let fm = FileManager.default
    var total: Int64 = 0
    if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
      for case let file as URL in e {
        total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
      }
    }
    return total
  }

  private static func timestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: Date())
  }

  /// LCS 合并 diff：返回按阅读顺序排列的差异行
  private static func diffLines(_ a: [String], _ b: [String]) -> [DiffLine] {
    let n = a.count, m = b.count
    var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
    for i in (0..<n).reversed() {
      for j in (0..<m).reversed() {
        if a[i] == b[j] { dp[i][j] = dp[i + 1][j + 1] + 1 }
        else { dp[i][j] = max(dp[i + 1][j], dp[i][j + 1]) }
      }
    }
    var result: [DiffLine] = []
    var i = 0, j = 0
    while i < n && j < m {
      if a[i] == b[j] {
        result.append(DiffLine(text: a[i], kind: .equal)); i += 1; j += 1
      } else if dp[i + 1][j] >= dp[i][j + 1] {
        result.append(DiffLine(text: a[i], kind: .removed)); i += 1
      } else {
        result.append(DiffLine(text: b[j], kind: .added)); j += 1
      }
    }
    while i < n { result.append(DiffLine(text: a[i], kind: .removed)); i += 1 }
    while j < m { result.append(DiffLine(text: b[j], kind: .added)); j += 1 }
    return result
  }

  /// LCS 左右双栏 diff：返回左右对齐的差异行（备份版左 / 当前版右）
  private static func diffLinesSideBySide(_ a: [String], _ b: [String]) -> [SideBySideLine] {
    let n = a.count, m = b.count
    var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
    for i in (0..<n).reversed() {
      for j in (0..<m).reversed() {
        if a[i] == b[j] { dp[i][j] = dp[i + 1][j + 1] + 1 }
        else { dp[i][j] = max(dp[i + 1][j], dp[i][j + 1]) }
      }
    }
    var result: [SideBySideLine] = []
    var li = 1, rj = 1   // 1-based 行号（与 git diff / FileMerge 等工具一致）
    var i = 0, j = 0
    while i < n && j < m {
      if a[i] == b[j] {
        result.append(SideBySideLine(leftNo: li, rightNo: rj, leftText: a[i], rightText: b[j], kind: .equal))
        i += 1; j += 1; li += 1; rj += 1
      } else if dp[i + 1][j] >= dp[i][j + 1] {
        // 备份版有、当前版无 → 删除行
        result.append(SideBySideLine(leftNo: li, rightNo: nil, leftText: a[i], rightText: "", kind: .removed))
        i += 1; li += 1
      } else {
        // 当前版有、备份版无 → 新增行
        result.append(SideBySideLine(leftNo: nil, rightNo: rj, leftText: "", rightText: b[j], kind: .added))
        j += 1; rj += 1
      }
    }
    while i < n {
      result.append(SideBySideLine(leftNo: li, rightNo: nil, leftText: a[i], rightText: "", kind: .removed))
      i += 1; li += 1
    }
    while j < m {
      result.append(SideBySideLine(leftNo: nil, rightNo: rj, leftText: "", rightText: b[j], kind: .added))
      j += 1; rj += 1
    }
    return result
  }
}

private extension String {
  var droppingLeadingSlash: String {
    if first == "/" { return String(dropFirst()) }
    return self
  }
}
