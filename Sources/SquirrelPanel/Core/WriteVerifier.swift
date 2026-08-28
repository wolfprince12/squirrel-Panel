//
//  WriteVerifier.swift
//  Squirrel Panel
//
//  写后回读校验：配置文件落盘后，重新解析并断言本次 PatchSet 中的每个键确实落地。
//  用于干掉「我以为写进去了其实没写进」的经典坑——未落地则调用方回滚 .bak 并抛错。
//
//  设计要点：
//  - 标量键（bool/int/double/string）严格比对值；
//  - 结构化键（列表/映射）由 Yams 往返序列化保证，仅校验「键存在」；
//  - value 为 nil 的键断言「应被删除」。
//

import Foundation
import Yams

enum WriteVerificationError: LocalizedError {
  case mismatch(String)

  var errorDescription: String? {
    switch self {
    case .mismatch(let msg):
      return "配置文件写后校验失败：\(msg)"
    }
  }
}

struct WriteVerifier {

  /// 校验已写入磁盘的文件：重新解析并核对 patchSet 中每个键的落地情况。
  /// - Parameters:
  ///   - fileURL: 已落盘（或临时）的文件路径
  ///   - patchSet: 本次写入的变更集；value 为 nil 表示期望删除该键
  static func verify(fileURL: URL, patchSet: PatchSet) throws {
    guard let text = try? String(contentsOf: fileURL, encoding: .utf8),
          let node = try? Yams.load(yaml: text) as? [String: Any] else {
      throw WriteVerificationError.mismatch("写入结果无法解析")
    }
    // 删光全部托管键后，patch: 段可能只剩注释而解析为 null——等同于空 patch（无托管键），
    // 此时所有「期望删除」的键都满足、所有「期望存在」的键都缺失，应按空字典处理而非报错。
    let patch = node["patch"] as? [String: Any] ?? [:]
    for (key, maybeValue) in patchSet {
      let actual = readFlat(patch: patch, key: key)
      if let value = maybeValue {
        guard actual != nil else {
          throw WriteVerificationError.mismatch("键 \(key) 写入后缺失")
        }
        switch value {
        case .bool, .int, .double, .string:
          guard scalarEqual(actual, value) else {
            throw WriteVerificationError.mismatch("键 \(key) 写入值与预期不符")
          }
        default:
          // 结构化值（列表/映射）由 Yams 往返序列化保证，仅校验存在性
          break
        }
      } else {
        guard actual == nil else {
          throw WriteVerificationError.mismatch("键 \(key) 应被删除但仍存在")
        }
      }
    }
  }

  // MARK: - 内部

  /// 按扁平路径读取 patch 节点下的值（如 "style/color_scheme"）；
  /// 同时兜底嵌套写法（极少数情况下键可能以真嵌套形式存在）。
  private static func readFlat(patch: [String: Any], key: String) -> Any? {
    if let v = patch[key] { return v }
    let parts = key.split(separator: "/").map(String.init)
    guard parts.count > 1 else { return nil }
    var node: Any? = patch
    for (i, p) in parts.enumerated() {
      if i == parts.count - 1 {
        return (node as? [String: Any])?[p]
      }
      guard let n = node as? [String: Any] else { return nil }
      node = n[p]
    }
    return nil
  }

  /// 标量值比较：归一化 Int / Double / String / Bool 的类型差异。
  private static func scalarEqual(_ actual: Any?, _ value: PatchValue) -> Bool {
    switch value {
    case .bool(let b):
      if let a = actual as? Bool { return a == b }
      if let a = actual as? String { return (a == "true") == b }
      return false
    case .int(let i):
      if let a = actual as? Int { return a == i }
      if let a = actual as? Double { return Int(a) == i }
      return false
    case .double(let d):
      if let a = actual as? Double { return a == d }
      if let a = actual as? Int { return Double(a) == d }
      return false
    case .string(let s):
      if let a = actual as? String { return a == s }
      return false
    default:
      return false
    }
  }
}
