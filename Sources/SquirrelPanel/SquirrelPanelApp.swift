//
//  SquirrelPanelApp.swift
//  Squirrel Panel — 鼠须管控制面板
//
//  一个独立于输入法本体的图形化配置工具。
//  不修改鼠须管本体，只读写 Rime 的补丁文件并通过官方通道触发部署。
//
//  2.0.0 起改为「菜单栏小老鼠」常驻形态：
//  - App 本体为 LSUIElement，无 Dock 图标，仅靠系统栏小老鼠图标常驻；
//  - 小老鼠在系统栏驻留时，AI 增强引擎与各模块自检轮询才启动；
//  - 小老鼠退出，AI 引擎与自检随之退出，且不影响鼠须管输入法本身；
//  - 左键点击小老鼠直接打开面板主程序（同时进入 Dock）；
//  - 右键菜单提供：AI 引擎启动 / 打开面板 / 退出。
//

import SwiftUI
import AppKit

/// 跨 App 与 AppDelegate 共享的常驻服务句柄。
/// 在 App.init 中装配，AppDelegate 在生命周期回调里读取，
/// 避免依赖 @NSApplicationDelegateAdaptor 的实例化时序。
@MainActor
final class AppServices {
  static let shared = AppServices()
  var store: SettingsStore!
  var iceStore: RimeIceConfigStore!
  var updateCenter: UpdateCenter!
}

@main
struct SquirrelPanelApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var store: SettingsStore
  @State private var iceStore: RimeIceConfigStore
  @State private var updateCenter: UpdateCenter

  @MainActor
  init() {
    let store = SettingsStore()
    let iceStore = RimeIceConfigStore(settings: store)
    store.rimeIce = iceStore
    // store.init() 内的脏值追踪注册时 rimeIce 尚为 nil，必须注入后重启一次，
    // 否则紫毫/雾凇面板的改动永不触发「应用并重新部署」按钮启用。
    store.restartDirtyTracking()
    _store = State(initialValue: store)
    _iceStore = State(initialValue: iceStore)
    _updateCenter = State(initialValue: UpdateCenter(store: store))

    // 装配常驻服务句柄，供 AppDelegate 生命周期使用
    AppServices.shared.store = store
    AppServices.shared.iceStore = iceStore
    AppServices.shared.updateCenter = updateCenter

    // 预热图片资源（后台线程，避免占用启动首帧）：紫毫示例图与关于页二维码
    // 改为内存缓存后，切换面板不再重复读盘。
    DispatchQueue.global(qos: .utility).async {
      AssetCache.warmUp()
    }
  }

  var body: some Scene {
    Window("", id: "main") {
      RootView()
        .environment(store)
        .environment(iceStore)
        .environment(updateCenter)
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  /// 主窗口的标识（Swizzling.swift 据此判断是否为「鼠须管控制面板」主窗口）。
  static let mainWindowIdentifier = "io.github.wolfprince12.squirrel-panel.main"

  /// 窗口尺寸兜底常量。SwiftUI `Window` + `NavigationSplitView` 在英文内容触发下
  /// 会出现首次启动时窗口被压缩到远小于 `minWidth/minHeight` 的 bug（PD 虚拟机尤其明显）。
  /// 这里在 AppKit 层强制最小尺寸与默认尺寸，避免 SwiftUI 布局引擎计算错误。
  private let mainWindowMinSize = NSSize(width: 880, height: 620)
  private let mainWindowDefaultSize = NSSize(width: 960, height: 860)

  private weak var mainWindow: NSWindow?

  // MARK: - 生命周期

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Thaw 同款修复：NavigationSplitView 的 sidebar 永不折叠。
    NSSplitViewItem.swizzle()

    // 主面板本身作为普通应用：有 Dock 图标，关闭窗口即退出进程。
    NSApp.setActivationPolicy(.regular)

    // SwiftUI Window scene 创建的 NSWindow 在此时已可用；取第一个并设置委托。
    if let window = NSApp.windows.first {
      attachMainWindow(window)
    } else {
      // 若窗口尚未创建，延迟一帧再取。
      DispatchQueue.main.async { [weak self] in
        if let window = NSApp.windows.first {
          self?.attachMainWindow(window)
        }
      }
    }

    // 主面板启动时跑各模块自检轮询（更新检查等）。
    AppServices.shared.updateCenter?.checkAllOnLaunch()

    // 启动即显示面板主窗口的逻辑下放到了 attachMainWindow：必须等 SwiftUI
    // 把工具栏 KVO 观察者装配平衡后再 orderFront，否则会在启动同步路径里
    // 触发 updateToolbarIfNeeded → removeObserver 失衡的 EXC_BREAKPOINT 崩溃。

    // 某些 autosave/布局计算会在启动后几帧内把窗口压小，追加多次兜底。
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      if let window = self?.mainWindow { self?.enforceMainWindowSize(window: window) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      if let window = self?.mainWindow { self?.enforceMainWindowSize(window: window) }
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // 关闭面板窗口即退出主面板进程，不再后台残留。
    true
  }

  // MARK: - 主窗口接管

  private func attachMainWindow(_ window: NSWindow) {
    mainWindow = window
    window.identifier = NSUserInterfaceItemIdentifier(AppDelegate.mainWindowIdentifier)
    window.delegate = self
    configureWindowAppearance(window)
    enforceMainWindowSize(window: window)
    // 启动即显示面板主窗口。延迟到下一轮 runloop 再 orderFront，让 SwiftUI
    // 先把工具栏 KVO 观察者装配平衡，避免 updateToolbarIfNeeded 里 removeObserver
    // 失衡导致的 EXC_BREAKPOINT 崩溃（崩溃栈：AppDelegate.showPanel → makeKeyAndOrderFront
    // → SwiftUI updateToolbarIfNeeded → removeObserver）。
    DispatchQueue.main.async { [weak self] in
      self?.showPanel()
    }
  }

  /// 点击 Dock 图标时重新唤出面板（仅当面板处于打开状态且 Dock 可见时）。
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if mainWindow == nil || mainWindow?.isVisible == false {
      showPanel()
    }
    return true
  }

  /// 点击面板红黄绿之外的「关闭」按钮：仅隐藏窗口（保持 .regular，不退出 Dock），
  /// 以便后续从 Dock 图标 / 双击 .app 再次唤出。
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    hidePanel()
    return false
  }

  // MARK: - 面板显隐（进入/退出 Dock）

  /// 打开（或唤出）面板主程序：切换为常规策略使其出现在 Dock，并前置窗口。
  private func showPanel() {
    NSApp.setActivationPolicy(.regular)
    mainWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  /// 关闭面板：仅隐藏窗口（保持 .regular，不退出 Dock）。
  /// ⚠️ 不再切 .accessory：主面板必须始终保持 .regular。若切 .accessory，关闭窗口后
  /// 主面板变 agent，此时双击 .app 会被 Launch Services 误判为「无常规 app 在运行」，
  /// 从而启动第二个主面板实例（Dock 出现两个图标）。保持 .regular 后，双击只会激活
  /// 已有实例，彻底消除该问题。
  private func hidePanel() {
    mainWindow?.orderOut(nil)
  }

  private func togglePanel() {
    if let window = mainWindow, window.isVisible {
      hidePanel()
    } else {
      showPanel()
    }
  }

  // MARK: - 窗口尺寸兜底

  func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
    NSSize(
      width: max(frameSize.width, mainWindowMinSize.width),
      height: max(frameSize.height, mainWindowMinSize.height)
    )
  }

  private func configureWindowAppearance(_ window: NSWindow) {
    // 窗口 chrome 完全默认（照搬 Thaw/Ice 正解）：不设任何 AppKit 外观——
    // 不 styleMask、不 titlebarAppearsTransparent、不 backgroundColor、不 toolbar。
    // NavigationSplitView 的 full-height sidebar 默认生效（交通灯浮在 sidebar 上、无暗条）。
    //
    // 关键坑：不要手动创建并赋值 `window.toolbar = NSToolbar()`！
    // 工具栏由 SwiftUI 的 AppKitWindowController 托管，它会在 `window.toolbar`
    // 上注册 KVO 观察者。手动把 toolbar 对象整个替换为新实例，会导致
    // orderFront 布局阶段的 updateToolbarIfNeeded 对「新」toolbar 调用
    // removeObserver，与已注册在「旧」toolbar 上的观察者不匹配，直接触发
    // EXC_BREAKPOINT 崩溃。所以这里绝不做任何 toolbar/titlebar 操作。
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
