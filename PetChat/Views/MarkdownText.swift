import SwiftUI

/// One block of a Pet reply. Inline text is kept as raw markdown and styled at render time.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case bullet(String)
    case numbered(Int, String)
    case code(String)
    case quote(String)
    case paragraph(String)
    case rule

    // ponytail: line-based parser; no nesting, tables, or setext headings. Unclosed fences (streaming) become code.
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }

        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if trimmed.hasPrefix("```") { blocks.append(.code(code!.joined(separator: "\n"))); code = nil } else { code!.append(line) }
            } else if trimmed.hasPrefix("```") {
                flush(); code = []
            } else if trimmed.isEmpty {
                flush()
            } else if let heading = heading(trimmed) {
                flush(); blocks.append(heading)
            } else if trimmed == "---" || trimmed == "***" {
                flush(); blocks.append(.rule)
            } else if trimmed.hasPrefix("> ") || trimmed == ">" {
                if !paragraph.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst(2)))
            } else if let item = listItem(trimmed) {
                flush(); blocks.append(item)
            } else {
                if !quote.isEmpty { flush() }
                paragraph.append(line)
            }
        }
        flush()
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let level = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level), line.dropFirst(level).first == " " else { return nil }
        return .heading(level: level, text: line.dropFirst(level).trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> MarkdownBlock? {
        if let marker = line.first, "-*+".contains(marker), line.dropFirst().first == " " {
            return .bullet(line.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }
        let digits = line.prefix(while: \.isNumber)
        let rest = line.dropFirst(digits.count)
        guard let n = Int(digits), let sep = rest.first, sep == "." || sep == ")", rest.dropFirst().first == " " else { return nil }
        return .numbered(n, rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }
}

/// Renders Pet reply markdown. Body text uses the caller's environment font.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(inline(text)).font(level <= 2 ? .title3.bold() : .body.bold())
        case let .bullet(text):
            item("•", text)
        case let .numbered(n, text):
            item("\(n).", text)
        case let .code(code):
            ScrollView(.horizontal) {
                Text(code).font(.system(.body, design: .monospaced)).padding(8)
            }
            .background(Palette.secondaryFill, in: RoundedRectangle(cornerRadius: 6))
        case let .quote(text):
            Text(inline(text)).foregroundStyle(Palette.secondaryText)
        case let .paragraph(text):
            Text(inline(text))
        case .rule:
            Divider()
        }
    }

    private func item(_ marker: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker)
            Text(inline(text))
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
