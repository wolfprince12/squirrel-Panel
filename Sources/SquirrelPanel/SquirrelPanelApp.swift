//
//  SquirrelPanelApp.swift
//  Squirrel Panel — 鼠须管控制面板
//
//  一个独立于输入法本体的图形化配置工具。
//  不修改鼠须管本体，只读写 Rime 的补丁文件并通过官方通道触发部署。
//

import SwiftUI
import AppKit

@main
struct SquirrelPanelApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var store: SettingsStore
  @StateObject private var iceStore: RimeIceConfigStore
  @StateObject private var updateCenter: UpdateCenter

  @MainActor
  init() {
    let store = SettingsStore()
    let iceStore = RimeIceConfigStore(settings: store)
    store.rimeIce = iceStore
    _store = StateObject(wrappedValue: store)
    _iceStore = StateObject(wrappedValue: iceStore)
    _updateCenter = StateObject(wrappedValue: UpdateCenter(store: store))
  }

  var body: some Scene {
    Window("app.name", id: "main") {
      RootView()
        .environmentObject(store)
        .environmentObject(iceStore)
        .environmentObject(updateCenter)
    }
    .defaultSize(width: 960, height: 860)
    .windowResizability(.contentMinSize)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandGroup(after: .saveItem) {
        Button("button.applyDeploy") { store.apply() }
          .keyboardShortcut("s", modifiers: .command)
          .disabled(!store.isDirty)
        Button("about.reload.button") { store.reload() }
          .keyboardShortcut("r", modifiers: .command)
        Divider()
        Button("menu.openUserDir") {
          SquirrelBridge.reveal(RimeEnvironment.userDirectory)
        }
      }
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  /// 窗口尺寸兜底常量。SwiftUI `Window` + `NavigationSplitView` 在英文内容触发下
  /// 会出现首次启动时窗口被压缩到远小于 `minWidth/minHeight` 的 bug（PD 虚拟机尤其明显）。
  /// 这里在 AppKit 层强制最小尺寸与默认尺寸，避免 SwiftUI 布局引擎计算错误。
  private let mainWindowMinSize = NSSize(width: 880, height: 620)
  private let mainWindowDefaultSize = NSSize(width: 960, height: 860)

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)

    // SwiftUI Window scene 创建的 NSWindow 在此时已可用；取第一个并设置委托。
    if let window = NSApp.windows.first {
      window.delegate = self
      configureWindowAppearance(window)
      enforceMainWindowSize(window: window)
    } else {
      // 若窗口尚未创建，延迟一帧再取。
      DispatchQueue.main.async { [weak self] in
        if let window = NSApp.windows.first {
          window.delegate = self
          self?.configureWindowAppearance(window)
          self?.enforceMainWindowSize(window: window)
        }
      }
    }

    // 某些 autosave/布局计算会在启动后几帧内把窗口压小，追加多次兜底。
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      if let window = NSApp.windows.first {
        self?.configureWindowAppearance(window)
        self?.enforceMainWindowSize(window: window)
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      if let window = NSApp.windows.first {
        self?.configureWindowAppearance(window)
        self?.enforceMainWindowSize(window: window)
      }
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
    NSSize(
      width: max(frameSize.width, mainWindowMinSize.width),
      height: max(frameSize.height, mainWindowMinSize.height)
    )
  }

  private func configureWindowAppearance(_ window: NSWindow) {
    // 让窗口内容延伸到标题栏区域，消除标题栏与内容区之间的视觉断层。
    // 这是 macOS 11+ 上 System Settings 等原生应用的常见处理方式。
    window.styleMask.insert(.fullSizeContentView)
    window.titlebarAppearsTransparent = true
    window.backgroundColor = NSColor.windowBackgroundColor
    window.titleVisibility = .hidden
  }

  private func enforceMainWindowSize(window: NSWindow) {
    window.minSize = mainWindowMinSize

    // 若当前帧异常小（如 SwiftUI autosave/calculation 出错），重置为默认尺寸。
    let frame = window.frame
    if frame.width < mainWindowMinSize.width || frame.height < mainWindowMinSize.height {
      let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
      let newFrame = NSRect(
        x: screenFrame.midX - mainWindowDefaultSize.width / 2,
        y: screenFrame.midY - mainWindowDefaultSize.height / 2,
        width: mainWindowDefaultSize.width,
        height: mainWindowDefaultSize.height
      )
      window.setFrame(newFrame, display: true, animate: false)
    }
  }
}
