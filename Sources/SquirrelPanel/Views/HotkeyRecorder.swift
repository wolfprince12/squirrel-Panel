//
//  HotkeyRecorder.swift
//  Squirrel Panel
//
//  方案切换快捷键录入框：聚焦后自动捕获用户按下的组合键，按 Rime 格式写入。
//  采用非可编辑的 NSTextField（不启用 field editor），以便直接接收 keyDown 事件。
//

import SwiftUI
import AppKit

struct HotkeyRecorder: NSViewRepresentable {
  @Binding var hotkey: String

  func makeNSView(context: Context) -> RecorderField {
    let field = RecorderField()
    field.captureDelegate = context.coordinator
    field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    field.isBordered = true
    field.bezelStyle = .roundedBezel
    field.drawsBackground = true
    field.alignment = .center
    field.isEditable = false
    field.isSelectable = false
    field.placeholderString = String(localized: "schema.hotkeys.recordHint")
    field.stringValue = hotkey
    return field
  }

  func updateNSView(_ field: RecorderField, context: Context) {
    if !field.isRecording {
      field.stringValue = hotkey
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  final class Coordinator: NSObject, RecorderFieldDelegate {
    var parent: HotkeyRecorder
    init(_ parent: HotkeyRecorder) { self.parent = parent }
    func recorderFieldDidCapture(_ combo: String) { parent.hotkey = combo }
  }
}

protocol RecorderFieldDelegate: AnyObject {
  func recorderFieldDidCapture(_ combo: String)
}

final class RecorderField: NSTextField {
  weak var captureDelegate: RecorderFieldDelegate?
  var isRecording = false

  override var acceptsFirstResponder: Bool { true }

  override func becomeFirstResponder() -> Bool {
    let ok = super.becomeFirstResponder()
    if ok { startRecording() }
    return ok
  }

  override func resignFirstResponder() -> Bool {
    let ok = super.resignFirstResponder()
    stopRecording()
    return ok
  }

  override func mouseDown(with event: NSEvent) {
    if isRecording {
      startRecording()
    } else {
      _ = window?.makeFirstResponder(self)
      if !isRecording { startRecording() }
    }
    super.mouseDown(with: event)
  }

  private func startRecording() {
    isRecording = true
    stringValue = ""
    placeholderString = String(localized: "schema.hotkeys.listening")
    backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18)
    needsDisplay = true
  }

  private func stopRecording() {
    isRecording = false
    placeholderString = String(localized: "schema.hotkeys.recordHint")
    backgroundColor = NSColor.textBackgroundColor
    needsDisplay = true
  }

  override func keyDown(with event: NSEvent) {
    // 非录制态：吞掉所有按键，禁用手动输入
    guard isRecording else { return }
    if event.keyCode == 0x35 {        // Escape 取消
      stopRecording()
      return
    }
    guard let combo = HotkeyFormatter.format(event: event) else {
      // 仅按下修饰键，继续等待真正按键
      return
    }
    captureDelegate?.recorderFieldDidCapture(combo)
    stopRecording()
  }
}

/// 将 NSEvent 转换为 Rime 风格的组合键字符串，例如 "Control+grave"、"Super+F4"。
enum HotkeyFormatter {
  static func format(event: NSEvent) -> String? {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    var mods: [String] = []
    if flags.contains(.control) { mods.append("Control") }
    if flags.contains(.option) { mods.append("Alt") }
    if flags.contains(.command) { mods.append("Super") }
    if flags.contains(.shift) { mods.append("Shift") }
    // 注意：Rime 的修饰键名是 Lock（不是 Caps_Lock），写错会导致整条热键被静默丢弃。
    if flags.contains(.capsLock) { mods.append("Lock") }

    guard let key = keyName(event: event), !key.isEmpty else { return nil }
    return (mods + [key]).joined(separator: "+")
  }

  private static let keyCodeNames: [UInt16: String] = [
    0x24: "Return", 0x30: "Tab", 0x31: "Space", 0x33: "BackSpace", 0x35: "Escape",
    0x7E: "Up", 0x7D: "Down", 0x7B: "Left", 0x7C: "Right",
    0x73: "Home", 0x77: "End", 0x74: "Page_Up", 0x79: "Page_Down",
    0x75: "Delete",
    0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5",
    0x61: "F6", 0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10",
    0x67: "F11", 0x6F: "F12", 0x69: "F13", 0x6B: "F14", 0x71: "F15",
    0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20"
  ]

  private static func keyName(event: NSEvent) -> String? {
    if let name = keyCodeNames[event.keyCode] { return name }
    guard let chars = event.charactersIgnoringModifiers,
          let first = chars.first else { return nil }
    let lower = String(first).lowercased()
    switch lower {
    case "`": return "grave"
    case "-": return "minus"
    case "=": return "equal"
    case "[": return "bracketleft"
    case "]": return "bracketright"
    case "\\": return "backslash"
    case ";": return "semicolon"
    case "'": return "apostrophe"
    case ",": return "comma"
    case ".": return "period"
    case "/": return "slash"
    default: return lower
    }
  }

  // MARK: - 校验（与 Rime / librime key_table 保持一致）

  /// Rime 认可的修饰键名（见 librime src/rime/key_table.cc 的 modifier_name 表）
  static let validModifiers: Set<String> = [
    "Shift", "Lock", "Control", "Alt", "Mod2", "Mod3", "Mod4", "Mod5",
    "Super", "Hyper", "Meta", "Release"
  ]

  /// Rime 认可的多字符键名（单字符键如 a/1/` 由 Rime 按 ASCII 直接解析，无需列出）
  static let validKeyNames: Set<String> = [
    "Return", "Tab", "Space", "BackSpace", "Escape", "Delete",
    "Up", "Down", "Left", "Right", "Home", "End", "Page_Up", "Page_Down",
    "Insert", "Prior", "Next", "Scroll_Lock", "Pause", "Sys_Req", "Menu", "Help",
    "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
    "F13", "F14", "F15", "F16", "F17", "F18", "F19", "F20",
    "grave", "minus", "equal", "bracketleft", "bracketright", "backslash",
    "semicolon", "apostrophe", "comma", "period", "slash"
  ]

  /// 校验单个组合键字符串是否为 Rime 可识别格式。
  /// - 返回 nil 表示合法；否则返回错误描述（含非法片段，便于调试）。
  static func validate(_ combo: String) -> String? {
    let tokens = combo.split(separator: "+").map(String.init)
    guard !tokens.isEmpty else { return "empty" }
    let key = tokens.last!
    let mods = tokens.dropLast()
    for m in mods {
      if !validModifiers.contains(m) { return "unknown modifier: \(m)" }
    }
    // 单字符键（字母/数字/标点）Rime 直接按 ASCII 解析，合法
    if key.count == 1 { return nil }
    if validKeyNames.contains(key) { return nil }
    return "unknown key: \(key)"
  }

  /// 该组合是否被 macOS 系统级占用（鼠须管作为输入法在绝大多数情况下收不到，
  /// 因此即使写入成功也无法调出方案切换菜单）。
  /// 返回该组合的小写形式（命中时），否则返回 nil。
  static func macOSReservedCombo(_ combo: String) -> String? {
    let c = combo.lowercased()
    let reserved: Set<String> = [
      "super+space", "super+shift+space",            // 切换输入法
      "super+tab", "super+shift+tab",               // 切换 App
      "control+space",                              // 通常也是切换输入法
      "super+grave", "super+shift+grave",           // 循环窗口
      "super+escape", "super+option+escape"         // 强制退出等
    ]
    return reserved.contains(c) ? c : nil
  }
}
