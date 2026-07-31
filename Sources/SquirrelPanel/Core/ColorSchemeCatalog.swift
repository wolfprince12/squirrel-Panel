//
//  ColorSchemeCatalog.swift
//  Squirrel Panel
//
//  扫描并解析所有可用的配色方案。
//
//  来源优先级与 Rime 一致：用户目录 squirrel.custom.yaml 中自定义的方案
//  会补充/覆盖 SharedSupport 里的内置方案。未安装鼠须管时回退到打包的官方副本。
//

import Foundation
import SwiftUI
import Yams

/// 一套配色方案
struct RimeColorSchemeInfo: Identifiable, Equatable {
  let id: String
  let name: String
  let author: String?
  let colorSpace: RimeColorSpace
  /// 原始颜色字段，键为 back_color 之类的短名
  let rawColors: [String: RimeColor]
  /// 是否来自用户自定义
  let isCustom: Bool

  // MARK: - 带回退的取色（回退链与 SquirrelTheme.swift 一致）

  private func raw(_ key: String) -> RimeColor? { rawColors[key] }

  var background: RimeColor { raw("back_color") ?? RimeColor(red: 1, green: 1, blue: 1, alpha: 1) }
  var border: RimeColor? { raw("border_color") }
  var preeditBackground: RimeColor? { raw("preedit_back_color") }
  var candidateBackground: RimeColor? { raw("candidate_back_color") }
  var highlightedPreeditBackground: RimeColor? { raw("hilited_back_color") }
  var highlightedCandidateBackground: RimeColor? {
    raw("hilited_candidate_back_color") ?? highlightedPreeditBackground
  }

  var text: RimeColor { raw("text_color") ?? RimeColor(red: 0, green: 0, blue: 0, alpha: 1) }
  var highlightedText: RimeColor { raw("hilited_text_color") ?? text }
  var candidateText: RimeColor { raw("candidate_text_color") ?? text }
  var highlightedCandidateText: RimeColor { raw("hilited_candidate_text_color") ?? highlightedText }
  var label: RimeColor { raw("label_color") ?? candidateText }
  var highlightedLabel: RimeColor { raw("hilited_candidate_label_color") ?? highlightedCandidateText }
  var comment: RimeColor { raw("comment_text_color") ?? candidateText }
  var highlightedComment: RimeColor { raw("hilited_comment_text_color") ?? highlightedCandidateText }

  func color(_ value: RimeColor) -> Color { value.swiftUIColor(in: colorSpace) }

  /// 系统默认配色（native）不定义任何颜色，交给系统绘制
  static let native = RimeColorSchemeInfo(
    id: "native",
    name: "系統／System",
    author: nil,
    colorSpace: .sRGB,
    rawColors: [
      "back_color": RimeColor(red: 1, green: 1, blue: 1, alpha: 1),
      "text_color": RimeColor(red: 0.54, green: 0.54, blue: 0.56, alpha: 1),
      "candidate_text_color": RimeColor(red: 0, green: 0, blue: 0, alpha: 1),
      "hilited_candidate_back_color": RimeColor(red: 0.04, green: 0.52, blue: 1, alpha: 1),
      "hilited_candidate_text_color": RimeColor(red: 1, green: 1, blue: 1, alpha: 1)
    ],
    isCustom: false
  )
}

enum ColorSchemeCatalog {

  /// 载入全部配色方案，按内置顺序排列，用户自定义的排在最后
  static func load(environment: RimeEnvironment, userPatch: CustomYAMLFile?) -> [RimeColorSchemeInfo] {
    var result: [RimeColorSchemeInfo] = []
    var seen = Set<String>()

    // 1. 内置（已安装则读实际文件，否则读打包副本）
    if let mapping = presetMapping(from: environment.builtinSquirrelYAML()) {
      for (id, body) in orderedEntries(mapping, in: environment.builtinSquirrelYAML()) {
        guard let scheme = parse(id: id, body: body, isCustom: false) else { continue }
        result.append(scheme)
        seen.insert(id)
      }
    }

    // 2. 用户在 squirrel.custom.yaml 里自定义的方案
    if let userPatch {
      for key in userPatch.topLevelKeys where key.hasPrefix("preset_color_schemes/") {
        let id = String(key.dropFirst("preset_color_schemes/".count))
        guard !id.contains("/"), let body = userPatch.value(forPath: key) as? [String: Any] else { continue }
        guard let scheme = parse(id: id, body: body, isCustom: true) else { continue }
        if let index = result.firstIndex(where: { $0.id == id }) {
          result[index] = scheme
        } else {
          result.append(scheme)
        }
        seen.insert(id)
      }
      if let nested = userPatch.value(forPath: "preset_color_schemes") as? [String: Any] {
        for (id, body) in nested {
          guard let body = body as? [String: Any],
                let scheme = parse(id: id, body: body, isCustom: true) else { continue }
          if let index = result.firstIndex(where: { $0.id == id }) {
            result[index] = scheme
          } else {
            result.append(scheme)
          }
          seen.insert(id)
        }
      }
    }

    if !seen.contains("native") {
      result.insert(.native, at: 0)
    }
    return result
  }

  // MARK: - 解析

  private static func presetMapping(from yaml: String) -> [String: Any]? {
    guard let object = try? Yams.load(yaml: yaml) as? [String: Any] else { return nil }
    return object["preset_color_schemes"] as? [String: Any]
  }

  /// YAML 字典解析后是无序的，这里按原文出现顺序还原，保证界面上的排列与官方一致
  private static func orderedEntries(_ mapping: [String: Any], in yaml: String) -> [(String, [String: Any])] {
    var order: [String] = []
    var inSection = false
    for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix("preset_color_schemes:") { inSection = true; continue }
      guard inSection else { continue }
      if !line.hasPrefix(" ") && !line.trimmingCharacters(in: .whitespaces).isEmpty { break }
      if line.hasPrefix("  ") && !line.hasPrefix("   ") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix(":"), !trimmed.hasPrefix("#") {
          order.append(String(trimmed.dropLast()))
        }
      }
    }
    var entries: [(String, [String: Any])] = []
    for key in order {
      if let body = mapping[key] as? [String: Any] { entries.append((key, body)) }
    }
    for (key, value) in mapping where !order.contains(key) {
      if let body = value as? [String: Any] { entries.append((key, body)) }
    }
    return entries
  }

  private static func parse(id: String, body: [String: Any], isCustom: Bool) -> RimeColorSchemeInfo? {
    var colors: [String: RimeColor] = [:]
    for (key, value) in body where key.hasSuffix("_color") {
      if let color = RimeColor(yamlValue: value) { colors[key] = color }
    }
    let name = (body["name"] as? String) ?? id
    if id == "native" && colors.isEmpty {
      return RimeColorSchemeInfo(id: "native", name: name, author: body["author"] as? String,
                                 colorSpace: .sRGB, rawColors: RimeColorSchemeInfo.native.rawColors,
                                 isCustom: isCustom)
    }
    return RimeColorSchemeInfo(
      id: id,
      name: name,
      author: body["author"] as? String,
      colorSpace: .from(name: (body["color_space"] as? String) ?? ""),
      rawColors: colors,
      isCustom: isCustom
    )
  }
}
