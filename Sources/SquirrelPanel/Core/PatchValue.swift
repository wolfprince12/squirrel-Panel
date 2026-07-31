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
    }
  }
}

/// 一组待写入的补丁：值为 nil 表示「移除该键」
typealias PatchSet = [String: PatchValue?]
