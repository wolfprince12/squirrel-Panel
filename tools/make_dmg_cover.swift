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

// 标题与说明文字放在窗口上方；三个图标（App / Applications / Fix）整体排在说明文字下方
// appdmg 坐标系 y=0 在窗口顶部，cover 生成器（NSImage lockFocus）y=0 在底部，
// 因此 PNG 顶距 = 480 - cover_y。文字顶距分别约为 48 / 90 / 132，图标中心在顶距 300，
// 图标（96px）顶距约 252，明显低于说明文字底部（约 140），间隔约 110px。
drawCenteredText("鼠须管控制面板", atY: 432, size: 42, weight: .bold, color: darkBlue)
drawCenteredText("Squirrel Panel", atY: 390, size: 24, weight: .regular, color: midBlue)
drawCenteredText("拖拽 App 到右侧 Applications 文件夹即可安装", atY: 348, size: 15, weight: .regular, color: gray)

// 不额外绘制图标标签，由 Finder 在图标下方自动显示真实文件名

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
