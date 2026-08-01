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
  @StateObject private var updateCenter: UpdateCenter

  @MainActor
  init() {
    let store = SettingsStore()
    _store = StateObject(wrappedValue: store)
    _updateCenter = StateObject(wrappedValue: UpdateCenter(store: store))
  }

  var body: some Scene {
    Window("app.name", id: "main") {
      RootView()
        .environmentObject(store)
        .environmentObject(updateCenter)
        .frame(minWidth: 880, minHeight: 620)
    }
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

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}
