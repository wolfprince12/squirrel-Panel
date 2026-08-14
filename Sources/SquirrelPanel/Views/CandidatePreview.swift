//
//  CandidatePreview.swift
//  Squirrel Panel
//
//  候选窗的实时预览。按当前配色、字体与 candidate_format 模板绘制，
//  让用户在写进配置之前就能看到效果。
//

import SwiftUI

/// candidate_format 模板中的一段
private enum FormatSegment: Equatable {
  case literal(String)
  case label
  case candidate
  case comment

  /// 解析 `[label]. [candidate] [comment]` 这类模板
  static func parse(_ format: String) -> [FormatSegment] {
    var segments: [FormatSegment] = []
    var buffer = ""
    var rest = Substring(format)
    let tokens: [(String, FormatSegment)] = [
      ("[label]", .label), ("[candidate]", .candidate), ("[comment]", .comment)
    ]
    outer: while !rest.isEmpty {
      for (token, segment) in tokens where rest.hasPrefix(token) {
        if !buffer.isEmpty { segments.append(.literal(buffer)); buffer = "" }
        segments.append(segment)
        rest = rest.dropFirst(token.count)
        continue outer
      }
      buffer.append(rest.removeFirst())
    }
    if !buffer.isEmpty { segments.append(.literal(buffer)) }
    return segments.isEmpty ? [.candidate] : segments
  }
}

/// 候选窗的实时预览（可复用）。给定一个配色方案，按当前全局样式（圆角、边框、字体、
/// candidate_format 等）绘制候选窗，让用户在写进配置之前就能看到效果。
/// 外观页与用户自定义配色编辑器共用同一实现。
struct CandidatePanel: View {
  let scheme: RimeColorSchemeInfo
  var height: CGFloat = 168
  @EnvironmentObject private var store: SettingsStore

  private static let samples: [(label: String, text: String, comment: String)] = [
    ("1", "鼠须管", "shu xu guan"),
    ("2", "输入法", ""),
    ("3", "书序管", ""),
    ("4", "鼠鬚管", "繁"),
    ("5", "數序館", "")
  ]

  var body: some View {
    ZStack {
      CheckerboardBackground()
      panel
        .padding(20)
    }
    .frame(height: height)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.08))
    )
  }

  private var panel: some View {
    VStack(alignment: .leading, spacing: store.preeditSpacing / 2) {
      if !store.inlinePreedit {
        Text("shu xu guan")
          .font(.system(size: max(8, store.fontPoint - 2)))
          .foregroundStyle(scheme.color(scheme.text))
      }
      candidateStack
    }
    .padding(.horizontal, max(6, store.borderWidth + 8))
    .padding(.vertical, max(5, store.borderHeight + 6))
    .background(
      RoundedRectangle(cornerRadius: store.cornerRadius, style: .continuous)
        .fill(scheme.color(scheme.background).opacity(store.alpha))
    )
    .overlay(
      RoundedRectangle(cornerRadius: store.cornerRadius, style: .continuous)
        .strokeBorder(scheme.border.map { scheme.color($0) } ?? .clear,
                      lineWidth: scheme.border == nil ? 0 : 1)
    )
    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
    .fixedSize()
  }

  @ViewBuilder
  private var candidateStack: some View {
    let segments = FormatSegment.parse(store.candidateFormat)
    let items = Array(Self.samples.prefix(max(1, min(store.pageSize, 5))).enumerated())

    if store.useLinearLayout {
      HStack(spacing: max(2, store.lineSpacing - 2)) {
        ForEach(items, id: \.offset) { index, sample in
          candidateCell(sample, highlighted: index == 0, segments: segments)
        }
      }
    } else {
      VStack(alignment: .leading, spacing: store.lineSpacing / 2) {
        ForEach(items, id: \.offset) { index, sample in
          candidateCell(sample, highlighted: index == 0, segments: segments)
        }
      }
    }
  }

  private func candidateCell(_ sample: (label: String, text: String, comment: String),
                             highlighted: Bool,
                             segments: [FormatSegment]) -> some View {
    let textColor = highlighted ? scheme.highlightedCandidateText : scheme.candidateText
    let labelColor = highlighted ? scheme.highlightedLabel : scheme.label
    let commentColor = highlighted ? scheme.highlightedComment : scheme.comment
    let background = highlighted
      ? scheme.highlightedCandidateBackground
      : scheme.candidateBackground

    return HStack(spacing: 0) {
      ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
        switch segment {
        case .literal(let text):
          Text(text)
            .font(previewFont(size: store.fontPoint))
            .foregroundStyle(scheme.color(textColor))
        case .label:
          Text(sample.label)
            .font(previewFont(size: store.labelFontPoint))
            .foregroundStyle(scheme.color(labelColor))
        case .candidate:
          Text(sample.text)
            .font(previewFont(size: store.fontPoint))
            .foregroundStyle(scheme.color(textColor))
        case .comment:
          if !sample.comment.isEmpty {
            Text(sample.comment)
              .font(previewFont(size: store.commentFontPoint))
              .foregroundStyle(scheme.color(commentColor))
          }
        }
      }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(
      RoundedRectangle(cornerRadius: store.hilitedCornerRadius, style: .continuous)
        .fill(background.map { scheme.color($0) } ?? .clear)
    )
    .rotationEffect(store.useVerticalText ? .degrees(0) : .zero)
  }

  private func previewFont(size: Double) -> Font {
    let name = store.fontFace.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    if name.isEmpty || NSFont(name: name, size: size) == nil {
      return .system(size: size)
    }
    return .custom(name, fixedSize: size)
  }
}

/// 外观页顶部使用的候选窗预览，使用当前生效的配色方案。
struct CandidatePreview: View {
  @EnvironmentObject private var store: SettingsStore

  var body: some View {
    CandidatePanel(scheme: store.currentScheme)
  }
}

/// 透明背景的棋盘格，用来展示候选窗的半透明效果
struct CheckerboardBackground: View {
  var body: some View {
    Canvas { context, size in
      let step: CGFloat = 8
      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(nsColor: .textBackgroundColor)))
      var row = 0
      var y: CGFloat = 0
      while y < size.height {
        var column = 0
        var x: CGFloat = 0
        while x < size.width {
          if (row + column).isMultiple(of: 2) {
            context.fill(Path(CGRect(x: x, y: y, width: step, height: step)),
                         with: .color(Color.primary.opacity(0.05)))
          }
          x += step
          column += 1
        }
        y += step
        row += 1
      }
    }
  }
}
