//
//  make_dmg_cover.swift
//  生成 DMG 封面背景图（820×380，适配 create-dmg）
//
//  用法：swift tools/make_dmg_cover.swift
//

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let logoURL = root.appending(path: "Resources/AppLogo.png")
let output = root.appending(path: "dist/DMG-Cover.png")

let size = CGSize(width: 820, height: 380)
let image = NSImage(size: size)
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else {
  image.unlockFocus()
  exit(1)
}

// 背景渐变
let colors = [
  NSColor(srgbRed: 0.95, green: 0.96, blue: 0.98, alpha: 1).cgColor,
  NSColor(srgbRed: 0.88, green: 0.91, blue: 0.95, alpha: 1).cgColor,
] as CFArray
if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: colors, locations: [0, 1]) {
  ctx.drawLinearGradient(gradient,
                         start: CGPoint(x: 0, y: 0),
                         end: CGPoint(x: 0, y: size.height),
                         options: [])
}

guard let logo = NSImage(contentsOf: logoURL) else {
  print("无法读取 logo")
  exit(1)
}

// 左侧大 logo
let logoRect = CGRect(x: 60, y: 60, width: 260, height: 260)
logo.draw(in: logoRect, from: .zero, operation: .sourceOver, fraction: 1)

// 右侧文字
func drawText(_ text: String, at point: CGPoint, size fontSize: CGFloat, weight: NSFont.Weight, color: NSColor) {
  let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
  let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: color,
  ]
  NSAttributedString(string: text, attributes: attrs).draw(at: point)
}

drawText("鼠须管控制面板", at: CGPoint(x: 360, y: 220), size: 42, weight: .bold, color: NSColor(srgbRed: 0.10, green: 0.22, blue: 0.38, alpha: 1))
drawText("Squirrel Panel", at: CGPoint(x: 360, y: 180), size: 24, weight: .regular, color: NSColor(srgbRed: 0.30, green: 0.40, blue: 0.52, alpha: 1))
drawText("拖拽 App 到右侧 Applications 文件夹即可安装", at: CGPoint(x: 360, y: 130), size: 15, weight: .regular, color: NSColor(srgbRed: 0.40, green: 0.45, blue: 0.52, alpha: 1))

image.unlockFocus()

try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
  print("导出失败")
  exit(1)
}
try png.write(to: output)
print("DMG 封面已生成：\(output.path)")
