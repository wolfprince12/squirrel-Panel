//
//  RimeColor.swift
//  Squirrel Panel
//
//  Rime 颜色字面量的解析与生成。
//
//  格式要点（与 SquirrelConfig.swift 的实现保持一致）：
//    0xAABBGGRR —— 八位，注意是 ABGR 倒序，不是常见的 ARGB
//    0xBBGGRR   —— 六位，不透明
//  另有 color_space 字段可取 srgb（默认）或 display_p3。
//

import Foundation
import SwiftUI

enum RimeColorSpace: String {
  case sRGB = "srgb"
  case displayP3 = "display_p3"

  static func from(name: String) -> RimeColorSpace {
    RimeColorSpace(rawValue: name.lowercased()) ?? .sRGB
  }
}

struct RimeColor: Equatable {
  var red: Double      // 0...1
  var green: Double
  var blue: Double
  var alpha: Double

  init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  // MARK: - 解析

  /// 从 YAML 取到的原始值解析颜色。
  ///
  /// YAML 1.1 会把 `0xF0E5F6FB` 直接读成整数，所以这里同时接受字符串与整数。
  init?(yamlValue: Any?) {
    switch yamlValue {
    case let text as String:
      guard let parsed = Self.parse(hexText: text) else { return nil }
      self = parsed
    case let number as Int:
      self = Self.parse(packed: UInt64(bitPattern: Int64(number)),
                        hasAlpha: number > 0xFFFFFF)
    default:
      return nil
    }
  }

  private static func parse(hexText: String) -> RimeColor? {
    let trimmed = hexText.trimmingCharacters(in: .whitespaces)
    guard trimmed.lowercased().hasPrefix("0x") else { return nil }
    let digits = String(trimmed.dropFirst(2))
    guard digits.count == 6 || digits.count == 8,
          let packed = UInt64(digits, radix: 16) else { return nil }
    return parse(packed: packed, hasAlpha: digits.count == 8)
  }

  private static func parse(packed: UInt64, hasAlpha: Bool) -> RimeColor {
    let alpha = hasAlpha ? Double((packed >> 24) & 0xFF) / 255 : 1
    let blue = Double((packed >> 16) & 0xFF) / 255
    let green = Double((packed >> 8) & 0xFF) / 255
    let red = Double(packed & 0xFF) / 255
    return RimeColor(red: red, green: green, blue: blue, alpha: alpha)
  }

  // MARK: - 生成

  /// 输出 Rime 认识的字面量。透明度为 1 时省略 alpha 段。
  var literal: String {
    let r = Int((red * 255).rounded())
    let g = Int((green * 255).rounded())
    let b = Int((blue * 255).rounded())
    if alpha >= 0.999 {
      return String(format: "0x%02X%02X%02X", b, g, r)
    }
    let a = Int((alpha * 255).rounded())
    return String(format: "0x%02X%02X%02X%02X", a, b, g, r)
  }

  // MARK: - SwiftUI 互操作

  func swiftUIColor(in space: RimeColorSpace) -> Color {
    switch space {
    case .displayP3:
      return Color(.displayP3, red: red, green: green, blue: blue, opacity: alpha)
    case .sRGB:
      return Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
  }

  init(_ color: Color, in space: RimeColorSpace) {
    let ns = NSColor(color).usingColorSpace(space == .displayP3 ? .displayP3 : .sRGB)
      ?? NSColor(color)
    self.red = Double(ns.redComponent)
    self.green = Double(ns.greenComponent)
    self.blue = Double(ns.blueComponent)
    self.alpha = Double(ns.alphaComponent)
  }
}
