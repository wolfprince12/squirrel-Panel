//
//  make_icon_from_logo.swift
//  从 Resources/AppLogo.png 生成 AppIcon.icns
//
//  用法：swift tools/make_icon_from_logo.swift
//

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let logoURL = root.appending(path: "Sources/SquirrelPanel/Resources/AppLogo.png")
let iconset = root.appending(path: "build-icon/AppIcon.iconset")

let fm = FileManager.default
try? fm.createDirectory(at: iconset, withIntermediateDirectories: true)

guard let logo = NSImage(contentsOf: logoURL) else {
  print("无法读取 logo: \(logoURL.path)")
  exit(1)
}

func drawIcon(size: CGFloat) -> NSImage {
  let image = NSImage(size: NSSize(width: size, height: size))
  image.lockFocus()
  guard NSGraphicsContext.current != nil else {
    image.unlockFocus()
    return image
  }

  // macOS 图标标准圆角：约为边长的 22%
  let cornerRadius = size * 0.22
  let bounds = CGRect(origin: .zero, size: CGSize(width: size, height: size))

  // 图标背景：用 logo 主色调深蓝
  let background = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
  NSColor(srgbRed: 0.10, green: 0.22, blue: 0.38, alpha: 1).setFill()
  background.fill()

  // 裁剪到圆角内，避免 logo 超出
  background.addClip()

  // logo 居中，留 8% 边距
  let padding = size * 0.08
  let logoRect = bounds.insetBy(dx: padding, dy: padding)
  logo.draw(in: logoRect, from: .zero, operation: .sourceOver, fraction: 1)

  image.unlockFocus()
  return image
}

let variants: [(String, CGFloat)] = [
  ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
  ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
  ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
  ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
  ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, size) in variants {
  let image = drawIcon(size: size)
  guard let tiff = image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:]) else {
    print("生成失败：\(name)")
    exit(1)
  }
  try png.write(to: iconset.appending(path: name))
}

print("iconset 已生成：\(iconset.path)")
