import SwiftUI

/// The markdown the models actually produce: headings, lists, code blocks, tables, rules, and inline bold, italic,
/// code and links (inline styles through AttributedString).
struct MarkdownText: View {
    let source: String

    private enum Block: Hashable {
        case para(String)
        case heading(Int, String)
        case item(String, String, Int)
        case code(String)
        case table([String])
        case rule
    }

    private static func parse(_ src: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        func flush() { if !para.isEmpty { out.append(.para(para.joined(separator: "\n"))); para = [] } }
        let lines = src.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                flush()
                var code: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.append(lines[i]); i += 1 }
                out.append(.code(code.joined(separator: "\n")))
            } else if t.isEmpty {
                flush()
            } else if t.range(of: #"^([-*_])(\s*\1){2,}$"#, options: .regularExpression) != nil {
                flush(); out.append(.rule)
            } else if let r = line.range(of: #"^#{1,4}\s+"#, options: .regularExpression) {
                flush()
                let level = line[r].filter { $0 == "#" }.count
                out.append(.heading(level, String(line[r.upperBound...])))
            } else if t.hasPrefix("|") {
                flush()
                var rows: [String] = []
                while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    let row = lines[i].trimmingCharacters(in: .whitespaces)
                    if row.range(of: #"^\|?\s*:?-{2,}"#, options: .regularExpression) == nil { rows.append(row) }
                    i += 1
                }
                out.append(.table(rows))
                continue
            } else if let r = line.range(of: #"^\s*([-*•]|\d+[.)])\s+"#, options: .regularExpression) {
                flush()
                let marker = line[r].trimmingCharacters(in: .whitespaces)
                let indent = line.prefix { $0 == " " }.count / 2
                out.append(.item(marker.first?.isNumber == true ? marker : "•", String(line[r.upperBound...]), indent))
            } else {
                para.append(line)
            }
            i += 1
        }
        flush()
        return out
    }

    private func inline(_ s: String) -> Text {
        let a = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        return Text(a)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownText.parse(source).enumerated()), id: \.offset) { _, b in
                switch b {
                case .para(let s): inline(s).font(.body)
                case .heading(let l, let s): inline(s).font(l <= 1 ? .title3.bold() : (l == 2 ? .headline : .subheadline.bold()))
                case .item(let m, let s, let indent):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(m).foregroundStyle(Theme.muted)
                        inline(s)
                    }.padding(.leading, CGFloat(indent) * 14)
                case .code(let s):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(s).font(.system(.footnote, design: .monospaced)).padding(10)
                    }.background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 8))
                case .table(let rows):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(rows.joined(separator: "\n")).font(.system(.footnote, design: .monospaced)).padding(8)
                    }.background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 8))
                case .rule: Divider()
                }
            }
        }
        .foregroundStyle(Theme.text)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
