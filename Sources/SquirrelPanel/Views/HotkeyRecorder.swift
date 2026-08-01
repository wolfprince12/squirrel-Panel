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
    if flags.contains(.capsLock) { mods.append("Caps_Lock") }

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
}
