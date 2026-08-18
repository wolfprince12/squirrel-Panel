//
//  DictionaryEditor.swift
//  Squirrel Panel
//
//  图形化编辑用户词库文件（custom_phrase.txt 及用户级 *.dict.yaml）。
//  底层复用 CustomPhraseFile：纯文本 tabledb 解析、注释/空行原样保留、
//  写盘前留 .bak 备份。编码（拼音）由系统 CFStringTransform 自动生成，
//  用户无需手写拼音即可新增词条。
//

import SwiftUI
import CoreFoundation

/// 把中文词语转成无声调、无空格的拼音编码（如「你好」→「nihao」）。
/// 用于新增词条时自动填充编码列，满足「不需要再去动编码」的诉求。
func autoPinyin(for word: String) -> String {
  guard !word.isEmpty else { return "" }
  let cf = NSMutableString(string: word) as CFMutableString
  CFStringTransform(cf, nil, kCFStringTransformToLatin, false)
  CFStringTransform(cf, nil, kCFStringTransformStripCombiningMarks, false)
  return (cf as String)
    .lowercased()
    .replacingOccurrences(of: " ", with: "")
}

/// 是否含 CJK 统一表意文字（用于判断词条是否为中文）
private func containsCJK(_ s: String) -> Bool {
  s.unicodeScalars.contains { $0.properties.isIdeographic }
}

/// 单个用户词库的图形化编辑器（以 sheet 形式呈现）。
struct DictionaryEditor: View {
  @Environment(SettingsStore.self) private var store
  @Environment(\.dismiss) private var dismiss

  @State private var file: CustomPhraseFile
  @State private var newWord = ""
  @State private var search = ""
  @State private var sort: EntrySort = .wordAsc
  @State private var message = ""
  @State private var errorText: String?
  @State private var saving = false
  @State private var confirmDiscard = false

  /// 词条排序方式
  enum EntrySort: String, CaseIterable, Identifiable {
    case wordAsc, wordDesc, codeAsc
    var id: String { rawValue }
    var title: LocalizedStringKey {
      switch self {
      case .wordAsc: return "dictionary.editor.sort.wordAsc"
      case .wordDesc: return "dictionary.editor.sort.wordDesc"
      case .codeAsc: return "dictionary.editor.sort.codeAsc"
      }
    }
  }

  init(url: URL) {
    _file = State(initialValue: CustomPhraseFile(fileURL: url))
  }

  /// 当前文件是否 .dict.yaml（这类文件多为挂载系统词库的配置，而非中文词条集合）
  private var isDictYAML: Bool {
    file.fileURL.lastPathComponent.hasSuffix(".dict.yaml")
  }

  /// 是否存在含汉字的可编辑条目
  private var hasCJKEntries: Bool {
    file.lines.contains { $0.isEntry && containsCJK($0.word) }
  }

  /// 列表表头：列宽与 entryRow 对齐
  private func headerRow() -> some View {
    HStack(spacing: 8) {
      Text("dictionary.editor.word")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
      Text("dictionary.editor.code")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 160, alignment: .leading)
      Text("dictionary.editor.weight")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 72, alignment: .leading)
      Spacer().frame(width: 24)
    }
  }

  /// 当前可见（过滤搜索 + 排序后）的可编辑条目在 `file.lines` 中的下标
  private var visibleIndices: [Int] {
    file.lines.indices
      .filter { file.lines[$0].isEntry }
      .filter {
        search.isEmpty
          || file.lines[$0].word.localizedCaseInsensitiveContains(search)
          || file.lines[$0].code.localizedCaseInsensitiveContains(search)
      }
      .sorted {
        let a = file.lines[$0], b = file.lines[$1]
        switch sort {
        case .wordAsc: return a.word.localizedStandardCompare(b.word) == .orderedAscending
        case .wordDesc: return a.word.localizedStandardCompare(b.word) == .orderedDescending
        case .codeAsc: return a.code.localizedStandardCompare(b.code) == .orderedAscending
        }
      }
  }

  var body: some View {
    VStack(spacing: 0) {
      // MARK: 标题栏
      HStack(spacing: 10) {
        Text(file.fileURL.lastPathComponent)
          .font(.headline)
        Spacer()
        if file.isDirty {
          Text("dictionary.editor.dirtyHint")
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)

      Divider()

      // MARK: 内容区
      VStack(spacing: 8) {
        // 列说明
        Text("dictionary.editor.legend")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)

        // 新增词条：只填中文，拼音自动生成
        HStack(spacing: 8) {
          TextField("dictionary.editor.addWord", text: $newWord)
            .textFieldStyle(.roundedBorder)
            .frame(width: 240)
          Button("dictionary.editor.add") { addWord() }
            .controlSize(.small)
            .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
          Text("dictionary.editor.addHint")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
        }

        // 搜索 + 排序 + 计数
        HStack(spacing: 8) {
          HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("dictionary.editor.search", text: $search)
              .textFieldStyle(.plain)
              .frame(width: 180)
          }
          HStack(spacing: 4) {
            Text("dictionary.editor.sort")
              .font(.caption)
              .foregroundStyle(.secondary)
            Picker("", selection: $sort) {
              ForEach(EntrySort.allCases) { s in
                Text(s.title).tag(s)
              }
            }
            .controlSize(.small)
            .labelsHidden()
            .frame(width: 150)
          }
          Spacer()
          Text(String(format: String(localized: "dictionary.editor.count"), file.entryCount))
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        // 列表表头：与下方条目三列对齐
        headerRow()
          .padding(.bottom, 4)

        Divider()

        // 条目列表
        ScrollView {
          VStack(spacing: 4) {
            // .dict.yaml 多为挂载系统词库的配置，可能完全没有中文条目
            if isDictYAML && !hasCJKEntries {
              HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("dictionary.editor.infoDictAggregator")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.bottom, 6)
            }
            if visibleIndices.isEmpty {
              Text("dictionary.editor.empty")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            }
            ForEach(visibleIndices, id: \.self) { i in
              entryRow(index: i)
            }
          }
          .padding(.vertical, 6)
        }
        .frame(maxHeight: .infinity)

        if !message.isEmpty {
          Text(message)
            .font(.caption)
            .foregroundStyle(.green)
        }
        if let errorText {
          Text(errorText)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)

      Divider()

      // MARK: 底部操作栏
      HStack(spacing: 12) {
        Button("dictionary.editor.close") { attemptClose() }
          .keyboardShortcut(.cancelAction)
          .buttonStyle(.bordered)
        Spacer()
        if saving {
          ProgressView()
            .controlSize(.small)
        }
        Button("dictionary.saveAndDeploy") { save() }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(saving || !file.isDirty)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
    .frame(minWidth: 640, minHeight: 480)
    .alert("dictionary.editor.discardConfirm", isPresented: $confirmDiscard) {
      Button("dictionary.editor.cancel", role: .cancel) {}
      Button("dictionary.editor.discard", role: .destructive) { dismiss() }
    }
  }

  private func entryRow(index i: Int) -> some View {
    HStack(spacing: 8) {
      TextField("dictionary.editor.word", text: Binding(
        get: { file.lines[i].word },
        set: { file.lines[i].word = $0 }))
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: .infinity)
      TextField("dictionary.editor.code", text: Binding(
        get: { file.lines[i].code },
        set: { file.lines[i].code = $0 }))
        .textFieldStyle(.roundedBorder)
        .font(.system(.caption, design: .monospaced))
        .frame(width: 160)
      TextField("0", text: Binding(
        get: { file.lines[i].weight },
        set: { file.lines[i].weight = $0 }))
        .textFieldStyle(.roundedBorder)
        .frame(width: 72)
      Button(action: { file.removeEntry(id: file.lines[i].id) }) {
        Image(systemName: "trash")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
    }
  }

  private func addWord() {
    let w = newWord.trimmingCharacters(in: .whitespaces)
    guard !w.isEmpty else { return }
    file.lines.append(PhraseLine(word: w, code: autoPinyin(for: w), weight: ""))
    newWord = ""
  }

  private func attemptClose() {
    if file.isDirty { confirmDiscard = true } else { dismiss() }
  }

  private func save() {
    saving = true
    errorText = nil
    message = ""
    Task {
      do {
        try file.save()
        try SquirrelBridge.deploy(environment: store.environment)
        await MainActor.run {
          saving = false
          message = String(localized: "dictionary.editor.saved")
          store.reload()
        }
      } catch {
        await MainActor.run {
          saving = false
          errorText = error.localizedDescription
        }
      }
    }
  }
}
