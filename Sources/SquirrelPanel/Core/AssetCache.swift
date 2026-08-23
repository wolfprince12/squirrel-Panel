//
//  AssetCache.swift
//  Squirrel Panel
//
//  图片资源的懒加载内存缓存。
//
//  面板切换卡顿的根因之一：紫毫纠错页与关于页在 body 里每次都同步
//  `NSImage(contentsOf: Bundle...)` 读盘，切一次读一次。
//  这里改为首次访问时加载并常驻内存，之后所有页面复用同一张 NSImage，
//  消除切换时的重复读盘开销。不阻塞启动路径（懒加载）。
//

import AppKit

enum AssetCache {
  /// 「爻知云」公众号二维码（关于页展示 + 另存下载来源由 Bundle 直读，不在此缓存）。
  static var yaozhiQRCode: NSImage? {
    yaozhiQRCodeCache ?? {
      guard let url = Bundle.main.url(forResource: "YaozhiQRCode", withExtension: "png") else { return nil }
      let image = NSImage(contentsOf: url)
      yaozhiQRCodeCache = image
      return image
    }()
  }

  /// 紫毫纠错模型示例截图（紫毫页展示）。
  static var amethystCorrectionDemo: NSImage? {
    amethystDemoCache ?? {
      guard let url = Bundle.main.url(forResource: "AmethystCorrectionDemo", withExtension: "png") else { return nil }
      let image = NSImage(contentsOf: url)
      amethystDemoCache = image
      return image
    }()
  }

  // MARK: - 私有缓存

  private static var yaozhiQRCodeCache: NSImage?
  private static var amethystDemoCache: NSImage?

  /// 在 App 启动后主动预热（后台线程调用，避免占用主线程首帧）。
  static func warmUp() {
    _ = yaozhiQRCode
    _ = amethystCorrectionDemo
  }
}
