//
//  AssociateBar.swift
//  SP-AIEnergyAgent — AI 联想层浮动条（Phase 2 MVP）
//
//  浮动联想条（AssociateBar）只托管在 Agent 常驻进程：
//  - 窗口为 borderless + nonactivatingPanel，不抢焦点、不参与 NSApp key/main 状态，
//    点击插入时前台 App 焦点保持不变（符合计划 3.2 要求）。
//  - 锚定到 Squirrel 候选窗口前方（上方），位置由 SquirrelWindowLocator 提供。
//  - 点击建议 → 经 Accessibility 把文本插入前台 App 光标处（未授权则回退剪贴板）。
//

import Foundation
import AppKit
import SwiftUI
import ApplicationServices

// MARK: - 联想条数据

struct AssociateSuggestion: Identifiable {
  let id = UUID()
  let text: String
}

// MARK: - 浮动窗口（不抢焦点）

final class AssociatePanel: NSPanel {
  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 44),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    level = .floating
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    hidesOnDeactivate = false
    isMovable = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

// MARK: - 联想条视图

struct AssociateBarView: View {
  let suggestions: [AssociateSuggestion]
  let onSelect: (String) -> Void

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(suggestions) { s in
          Button(action: { onSelect(s.text) }) {
            Text(s.text)
              .font(.system(size: 14, weight: .regular))
              .lineLimit(1)
              .truncationMode(.tail)
              .padding(.horizontal, 12)
              .padding(.vertical, 6)
              .frame(maxWidth: 320)
          }
          .buttonStyle(.plain)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(Color(nsColor: .controlBackgroundColor))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
          )
        }
      }
      .padding(8)
    }
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 3)
    )
  }
}

// MARK: - 控制器

@MainActor
final class AssociateBarController {
  private var panel: AssociatePanel?
  private var lastAnchor: NSRect?

  /// 显示联想条。texts 为 2–3 条续写建议；anchor 为 Squirrel 候选窗矩形（Cocoa 全局坐标）。
  func show(suggestions texts: [String], anchor: NSRect) {
    let items = texts.map { AssociateSuggestion(text: $0) }
    guard !items.isEmpty else { hide(); return }

    let panel = ensurePanel()
    let hosting = NSHostingController(rootView: AssociateBarView(suggestions: items) { [weak self] t in
      self?.insert(text: t)
    })
    hosting.view.layoutSubtreeIfNeeded()
    panel.contentViewController = hosting

    var size = hosting.view.fittingSize
    if size.width < 1 || size.height < 1 { size = NSSize(width: 320, height: 44) }
    size.width = min(max(size.width, 120), 760)
    size.height = max(size.height, 44)
    panel.setContentSize(size)

    position(panel: panel, anchor: anchor, size: size)
    lastAnchor = anchor
    panel.orderFrontRegardless()
  }

  func hide() {
    panel?.orderOut(nil)
  }

  /// 仅刷新位置（候选窗移动时调用）。
  func reflow() {
    guard let panel, let anchor = lastAnchor, panel.isVisible else { return }
    var size = panel.contentLayoutRect.size
    if size.width < 1 { size = NSSize(width: 320, height: 44) }
    position(panel: panel, anchor: anchor, size: size)
  }

  private func ensurePanel() -> AssociatePanel {
    if let p = panel { return p }
    let p = AssociatePanel()
    panel = p
    return p
  }

  /// 贴在候选窗上方 8px；空间不足（接近屏幕顶）则落到候选窗下方。
  private func position(panel: AssociatePanel, anchor: NSRect, size: NSSize) {
    let gap: CGFloat = 8
    var x = anchor.midX - size.width / 2
    var y = anchor.maxY + gap
    let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }) ?? NSScreen.main
    if let screen {
      if y + size.height > screen.visibleFrame.maxY {
        y = anchor.minY - gap - size.height
      }
      x = min(max(x, screen.visibleFrame.minX + 4), screen.visibleFrame.maxX - size.width - 4)
    }
    panel.setFrameOrigin(NSPoint(x: x, y: y))
  }

  /// 点击建议 → 经 Accessibility 插入前台 App 光标处。未授权则回退剪贴板。
  private func insert(text: String) {
    hide()
    guard AXIsProcessTrusted() else {
      print("[AssociateBar] 未授权辅助功能，无法自动插入；已复制到剪贴板，请手动粘贴。")
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      return
    }
    let sys = AXUIElementCreateSystemWide()
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let el = focused else { return }
    let element = el as! AXUIElement
    AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
  }
}
