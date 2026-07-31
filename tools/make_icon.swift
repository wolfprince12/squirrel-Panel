//
//  make_icon.swift
//  生成 Resources/AppIcon.icns
//
//  用法：swift tools/make_icon.swift
//  纯 AppKit 绘制，不依赖任何外部素材。
//

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appending(path: "build-icon/AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// 在 1024×1024 的坐标系里绘制，再按目标尺寸缩放
func draw(size: CGFloat) -> NSImage {
  let image = NSImage(size: NSSize(width: size, height: size))
  image.lockFocus()
  guard let ctx = NSGraphicsContext.current?.cgContext else {
    image.unlockFocus()
    return image
  }
  let s = size / 1024.0
  ctx.scaleBy(x: s, y: s)
  ctx.setAllowsAntialiasing(true)

  // 背景：macOS 风格圆角方块 + 竖向渐变
  let inset: CGFloat = 84
  let rect = CGRect(x: inset, y: inset, width: 1024 - inset * 2, height: 1024 - inset * 2)
  let bg = NSBezierPath(roundedRect: rect, xRadius: 200, yRadius: 200)
  ctx.saveGState()
  bg.addClip()
  let colors = [
    NSColor(srgbRed: 0.16, green: 0.18, blue: 0.24, alpha: 1).cgColor,
    NSColor(srgbRed: 0.09, green: 0.10, blue: 0.14, alpha: 1).cgColor,
  ] as CFArray
  if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: colors, locations: [0, 1]) {
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: 1024),
                           end: CGPoint(x: 0, y: 0),
                           options: [])
  }
  ctx.restoreGState()

  // 顶部高光描边
  NSColor(white: 1, alpha: 0.10).setStroke()
  let stroke = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 198, yRadius: 198)
  stroke.lineWidth = 4
  stroke.stroke()

  // 候选条：白色卡片
  let card = CGRect(x: 168, y: 396, width: 688, height: 232)
  let cardPath = NSBezierPath(roundedRect: card, xRadius: 56, yRadius: 56)
  NSColor(srgbRed: 0.97, green: 0.97, blue: 0.96, alpha: 1).setFill()
  cardPath.fill()

  // 高亮候选项（橙色胶囊）
  let hilite = CGRect(x: 208, y: 436, width: 208, height: 152)
  let hilitePath = NSBezierPath(roundedRect: hilite, xRadius: 40, yRadius: 40)
  NSColor(srgbRed: 0.95, green: 0.52, blue: 0.18, alpha: 1).setFill()
  hilitePath.fill()

  // 高亮项内的「鼠」字
  func drawGlyph(_ text: String, in box: CGRect, size fontSize: CGFloat, color: NSColor) {
    let font = NSFont(name: "PingFang SC Semibold", size: fontSize)
      ?? NSFont.systemFont(ofSize: fontSize, weight: .semibold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let str = NSAttributedString(string: text, attributes: attrs)
    let bounds = str.size()
    let origin = CGPoint(x: box.midX - bounds.width / 2,
                         y: box.midY - bounds.height / 2)
    str.draw(at: origin)
  }

  drawGlyph("鼠", in: hilite, size: 108, color: .white)

  // 后续两个未选中候选项
  let dim = NSColor(srgbRed: 0.22, green: 0.24, blue: 0.28, alpha: 1)
  drawGlyph("须", in: CGRect(x: 452, y: 436, width: 176, height: 152), size: 100, color: dim)
  drawGlyph("管", in: CGRect(x: 636, y: 436, width: 176, height: 152), size: 100, color: dim)

  // 底部三个滑杆，暗示「这是设置面板」
  let track = NSColor(white: 1, alpha: 0.22)
  let knob = NSColor(srgbRed: 0.42, green: 0.72, blue: 0.98, alpha: 1)
  let rows: [(CGFloat, CGFloat)] = [(320, 0.72), (248, 0.42), (176, 0.58)]
  for (y, ratio) in rows {
    let full = CGRect(x: 216, y: y, width: 592, height: 26)
    track.setFill()
    NSBezierPath(roundedRect: full, xRadius: 13, yRadius: 13).fill()
    knob.setFill()
    let filled = CGRect(x: 216, y: y, width: 592 * ratio, height: 26)
    NSBezierPath(roundedRect: filled, xRadius: 13, yRadius: 13).fill()
    NSColor.white.setFill()
    let dot = CGRect(x: 216 + 592 * ratio - 22, y: y - 9, width: 44, height: 44)
    NSBezierPath(ovalIn: dot).fill()
  }

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
  let image = draw(size: size)
  guard let tiff = image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:]) else {
    print("生成失败：\(name)")
    exit(1)
  }
  try png.write(to: iconset.appending(path: name))
}

print("iconset 已生成：\(iconset.path)")
