//
//  Swizzling.swift
//  Squirrel Panel
//
//  SwiftUI 的 NavigationSplitView 在部分 macOS 版本/环境下会出现
//  sidebar 被自动折叠（只剩图标、甚至消失）的 bug（英文系统与 PD 虚拟机
//  尤其明显）。本文件参考 Thaw（Ice 的分支）的解法：
//  交换 NSSplitViewItem.canCollapse 的 getter，对主窗口强制返回 false，
//  使 sidebar 永不折叠，彻底消除该布局问题。
//

import Cocoa

extension NSSplitViewItem {
  @MainActor
  @nonobjc private static let swizzler: () = {
    let originalCanCollapseSel = #selector(getter: canCollapse)
    let swizzledCanCollapseSel = #selector(getter: swizzledCanCollapse)
    if
      let originalCanCollapseMethod = class_getInstanceMethod(NSSplitViewItem.self, originalCanCollapseSel),
      let swizzledCanCollapseMethod = class_getInstanceMethod(NSSplitViewItem.self, swizzledCanCollapseSel)
    {
      method_exchangeImplementations(originalCanCollapseMethod, swizzledCanCollapseMethod)
    }

    let originalResizeCollapseSel = #selector(getter: canCollapseFromWindowResize)
    let swizzledResizeCollapseSel = #selector(getter: swizzledCanCollapseFromWindowResize)
    if
      let originalResizeCollapseMethod = class_getInstanceMethod(NSSplitViewItem.self, originalResizeCollapseSel),
      let swizzledResizeCollapseMethod = class_getInstanceMethod(NSSplitViewItem.self, swizzledResizeCollapseSel)
    {
      method_exchangeImplementations(originalResizeCollapseMethod, swizzledResizeCollapseMethod)
    }
  }()

  @MainActor
  @objc private var swizzledCanCollapse: Bool {
    // 仅对鼠须管控制面板的主窗口生效；其它系统组件不受影响。
    if let window = viewController.view.window,
       window.identifier?.rawValue == AppDelegate.mainWindowIdentifier {
      return false
    }
    return self.swizzledCanCollapse
  }

  @MainActor
  @objc private var swizzledCanCollapseFromWindowResize: Bool {
    // 同上：窗口尺寸变化触发 sidebar 折叠的入口也一并禁用。
    if let window = viewController.view.window,
       window.identifier?.rawValue == AppDelegate.mainWindowIdentifier {
      return false
    }
    return self.swizzledCanCollapseFromWindowResize
  }

  @MainActor
  static func swizzle() {
    _ = swizzler
  }
}
