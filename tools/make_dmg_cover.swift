//
//  make_dmg_cover.swift
//  生成 DMG 封面背景图（820×480，与 appdmg 窗口尺寸一致）
//
//  用法：swift tools/make_dmg_cover.swift
//

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let logoURL = root.appending(path: "Resources/AppLogo.png")
let output = root.appending(path: "dist/DMG-Cover.png")

let size = CGSize(width: 820, height: 480)
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

// 标题文字（上方居中）
func drawCenteredText(_ text: String, atY y: CGFloat, size fontSize: CGFloat, weight: NSFont.Weight, color: NSColor) {
  let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
  let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: color,
  ]
  let str = NSAttributedString(string: text, attributes: attrs)
  let textSize = str.size()
  let point = CGPoint(x: (size.width - textSize.width) / 2, y: y)
  str.draw(at: point)
}

let darkBlue = NSColor(srgbRed: 0.10, green: 0.22, blue: 0.38, alpha: 1)
let midBlue = NSColor(srgbRed: 0.30, green: 0.40, blue: 0.52, alpha: 1)
let gray = NSColor(srgbRed: 0.40, green: 0.45, blue: 0.52, alpha: 1)

drawCenteredText("鼠须管控制面板", atY: 370, size: 42, weight: .bold, color: darkBlue)
drawCenteredText("Squirrel Panel", atY: 325, size: 24, weight: .regular, color: midBlue)
drawCenteredText("拖拽 App 到右侧 Applications 文件夹即可安装", atY: 280, size: 15, weight: .regular, color: gray)

// 下方两个 faint label，分别对应 App 与 Applications 位置
// appdmg 中 App 位于 x=270, Applications 位于 x=550，图标底部 y≈120
drawCenteredText("Squirrel Panel.app", atY: 80, size: 13, weight: .medium, color: midBlue)
drawCenteredText("Applications", atY: 80, size: 13, weight: .medium, color: midBlue)

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
