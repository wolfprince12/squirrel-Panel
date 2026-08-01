//
//  PatchValue.swift
//  Squirrel Panel
//
//  补丁值的类型封装。用它而不是 Any，是为了让「有没有改动」可以直接用 == 判断，
//  同时保证写进 YAML 的类型正确（Rime 对 bool 与字符串 "true" 的处理并不相同）。
//

import Foundation

enum PatchValue: Equatable {
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  case stringList([String])
  case schemaList([String])
  /// Rime 的 key_bindings 列表（每个元素是 [String: Any] 的映射）
  case keyBindings([[String: Any]])

  /// 转换成可交给 Yams 序列化的对象
  var yamlObject: Any {
    switch self {
    case .bool(let v): return v
    case .int(let v): return v
    case .double(let v):
      // 整数值写成整数，避免 16.0 这种冗余写法
      return v == v.rounded() && abs(v) < 1e9 ? Int(v) : v
    case .string(let v): return v
    case .stringList(let v): return v
    case .schemaList(let v): return v.map { ["schema": $0] }
    case .keyBindings(let v): return v
    }
  }

  static func == (lhs: PatchValue, rhs: PatchValue) -> Bool {
    switch (lhs, rhs) {
    case (.bool(let a), .bool(let b)): return a == b
    case (.int(let a), .int(let b)): return a == b
    case (.double(let a), .double(let b)): return a == b
    case (.string(let a), .string(let b)): return a == b
    case (.stringList(let a), .stringList(let b)): return a == b
    case (.schemaList(let a), .schemaList(let b)): return a == b
    case (.keyBindings(let a), .keyBindings(let b)):
      guard a.count == b.count else { return false }
      for (x, y) in zip(a, b) {
        guard Set(x.keys) == Set(y.keys) else { return false }
        for key in x.keys {
          guard let vx = x[key], let vy = y[key] else { return false }
          if !valueEqual(vx, vy) { return false }
        }
      }
      return true
    default:
      return false
    }
  }

  private static func valueEqual(_ a: Any, _ b: Any) -> Bool {
    switch (a, b) {
    case (let s1 as String, let s2 as String): return s1 == s2
    case (let i1 as Int, let i2 as Int): return i1 == i2
    case (let d1 as Double, let d2 as Double): return d1 == d2
    case (let b1 as Bool, let b2 as Bool): return b1 == b2
    default: return false
    }
  }
}

/// 一组待写入的补丁：值为 nil 表示「移除该键」
typealias PatchSet = [String: PatchValue?]
