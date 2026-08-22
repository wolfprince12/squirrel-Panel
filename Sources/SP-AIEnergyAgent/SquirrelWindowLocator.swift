//
//  SquirrelWindowLocator.swift
//  SP-AIEnergyAgent — 定位 Squirrel 输入法候选窗口（Phase 2 MVP）
//
//  浮动条需要锚定到 Squirrel 的候选窗口，但控制面板/Agent 是独立进程，
//  不知道别的 App 光标在哪。唯一可靠的本地坐标来源是 Squirrel 自己——
//  它本就画出候选窗口。这里用 CGWindowList 枚举窗口、按 owner 名含
//  "Squirrel" 过滤，排除全屏/超大窗口（如偏好面板），取剩下的「最小」窗口
//  作为候选窗，再换算到 Cocoa 全局坐标供浮动条定位。
//

import Foundation
import AppKit

enum SquirrelWindowLocator {
  /// 返回 Squirrel 候选窗口的屏幕矩形（Cocoa 全局坐标，原点主屏左下，y 向上）。
  /// 找不到时返回 nil（调用方应回退到默认位置或隐藏）。
  static func candidateWindowRect() -> NSRect? {
    let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }

    let candidates: [(rect: CGRect, layer: Int)] = list.compactMap { info in
      guard let owner = info[kCGWindowOwnerName as String] as? String,
            owner.localizedCaseInsensitiveContains("Squirrel"),
            let bounds = info[kCGWindowBounds as String] as? [String: Double],
            let x = bounds["X"], let y = bounds["Y"],
            let w = bounds["Width"], let h = bounds["Height"],
            w > 20, h > 20
      else { return nil }
      let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
      return (CGRect(x: x, y: y, width: w, height: h), layer)
    }

    guard !candidates.isEmpty else { return nil }

    // 排除过大窗口（> 主屏 60%，通常是偏好面板之类），剩下的取最小者作为候选窗。
    let primary = NSScreen.screens.first?.frame.size ?? NSSize(width: 1920, height: 1080)
    let area = primary.width * primary.height
    let small = candidates.filter { $0.rect.width * $0.rect.height < area * 0.6 }
    let picked = (small.isEmpty ? candidates : small)
      .min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }!

    return convertToCocoa(picked.rect)
  }

  /// CoreGraphics 坐标（原点主屏左上，y 向下）→ Cocoa 坐标（原点主屏左下，y 向上）。
  private static func convertToCocoa(_ cg: CGRect) -> NSRect {
    let primaryHeight = NSScreen.screens[0].frame.height
    let y = primaryHeight - cg.origin.y - cg.height
    return NSRect(x: cg.origin.x, y: y, width: cg.width, height: cg.height)
  }
}
