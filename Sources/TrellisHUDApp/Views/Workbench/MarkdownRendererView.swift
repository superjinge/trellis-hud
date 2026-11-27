import AppKit
import Foundation
import SwiftUI

// MARK: - Parsed Markdown AST

struct MarkdownDocument: Sendable, Equatable {
    var frontmatter: [(key: String, value: String)]
    var leadingBlocks: [MarkdownBlock]
    var sections: [MarkdownSection]

    static func == (lhs: MarkdownDocument, rhs: MarkdownDocument) -> Bool {
        lhs.leadingBlocks == rhs.leadingBlocks
            && lhs.sections == rhs.sections
            && lhs.frontmatter.map(\.key) == rhs.frontmatter.map(\.key)
            && lhs.frontmatter.map(\.value) == rhs.frontmatter.map(\.value)
    }
}

struct MarkdownSection: Identifiable, Sendable, Equatable {
    var id: String
    var title: String
    var blocks: [MarkdownBlock]
}

enum MarkdownBlock: Identifiable, Sendable, Equatable {
    case heading(id: String, level: Int, text: String)
    case paragraph(id: String, text: String)
    case codeBlock(id: String, language: String?, code: String)
    case checklist(id: String, items: [ChecklistEntry])
    case list(id: String, ordered: Bool, items: [ListEntry])
    case blockquote(id: String, lines: [String])
    case table(id: String, headers: [String], alignments: [TableAlignment], rows: [[String]])
    case thematicBreak(id: String)

    var id: String {
        switch self {
        case .heading(let id, _, _),
             .paragraph(let id, _),
             .codeBlock(let id, _, _),
             .checklist(let id, _),
             .list(let id, _, _),
             .blockquote(let id, _),
             .table(let id, _, _, _),
             .thematicBreak(let id):
            return id
        }
    }

    struct ChecklistEntry: Identifiable, Sendable, Equatable {
        var id: String
        var checked: Bool
        var indent: Int
        var text: String
    }

    struct ListEntry: Identifiable, Sendable, Equatable {
        var id: String
        var index: Int
        var indent: Int
        var text: String
    }

    enum TableAlignment: Sendable, Equatable {
        case leading
        case center
        case trailing

        var swiftUIAlignment: Alignment {
            switch self {
            case .leading: return .leading
            case .center: return .center
            case .trailing: return .trailing
            }
        }

        var textAlignment: TextAlignment {
            switch self {
            case .leading: return .leading
            case .center: return .center
            case .trailing: return .trailing
            }
        }
    }
}

// MARK: - GFM Parser

enum MarkdownParser {
    static func parse(_ source: String) -> MarkdownDocument {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let allLines = normalized.components(separatedBy: "\n")

        var cursor = 0
        let frontmatter = parseFrontmatter(lines: allLines, cursor: &cursor)
        let blocks = parseBlocks(lines: allLines, startIndex: cursor)

        var leadingBlocks: [MarkdownBlock] = []
        var sections: [MarkdownSection] = []
        var currentSection: MarkdownSection?

        for block in blocks {
            if case .heading(let id, let level, let text) = block, level == 2 {
                if let active = currentSection {
                    sections.append(active)
                }
                currentSection = MarkdownSection(id: "sec-\(id)", title: text, blocks: [])
            } else if currentSection != nil {
                currentSection?.blocks.append(block)
            } else {
                leadingBlocks.append(block)
            }
        }
        if let active = currentSection {
            sections.append(active)
        }

        return MarkdownDocument(
            frontmatter: frontmatter,
            leadingBlocks: leadingBlocks,
            sections: sections
        )
    }

    private static func parseFrontmatter(
        lines: [String],
        cursor: inout Int
    ) -> [(key: String, value: String)] {
        guard lines.count >= 3,
              lines[0].trimmingCharacters(in: .whitespaces) == "---" else {
            return []
        }

        var endIndex: Int?
        for idx in 1..<min(lines.count, 80) {
            let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." {
                endIndex = idx
                break
            }
        }
        guard let end = endIndex else { return [] }

        var entries: [(key: String, value: String)] = []
        var currentKey: String?
        var listValues: [String] = []

        func flushCurrent() {
            if let key = currentKey, !listValues.isEmpty {
                entries.append((key: key, value: listValues.joined(separator: ", ")))
            }
            currentKey = nil
            listValues = []
        }

        for idx in 1..<end {
            let raw = lines[idx]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed.hasPrefix("- "), currentKey != nil {
                let item = String(trimmed.dropFirst(2))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                listValues.append(item)
                continue
            }

            if let colon = trimmed.firstIndex(of: ":") {
                flushCurrent()
                let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                let val = String(trimmed[trimmed.index(after: colon)...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                if val.isEmpty {
                    currentKey = key
                } else {
                    entries.append((key: key, value: val))
                }
            }
        }
        flushCurrent()

        cursor = end + 1
        return entries
    }

    private static func parseBlocks(lines: [String], startIndex: Int) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var i = startIndex
        var blockSeq = 0

        func nextId(_ prefix: String) -> String {
            defer { blockSeq += 1 }
            return "\(prefix)-\(blockSeq)"
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Fenced code block (``` or ~~~)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fenceChar = trimmed.first!
                let fenceLen = trimmed.prefix(while: { $0 == fenceChar }).count
                let fencePrefix = String(repeating: String(fenceChar), count: fenceLen)
                let info = String(trimmed.dropFirst(fenceLen)).trimmingCharacters(in: .whitespaces)
                let language = info.isEmpty ? nil : info.components(separatedBy: .whitespaces).first
                i += 1
                var codeLines: [String] = []
                while i < lines.count {
                    let candidate = lines[i].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fencePrefix),
                       candidate.dropFirst(fenceLen).trimmingCharacters(in: .whitespaces).isEmpty {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(
                    id: nextId("code"),
                    language: language,
                    code: codeLines.joined(separator: "\n")
                ))
                continue
            }

            // Thematic break (---, ***, ___)
            if isThematicBreak(trimmed) {
                blocks.append(.thematicBreak(id: nextId("hr")))
                i += 1
                continue
            }

            // ATX Heading (# .. ####)
            if let heading = parseHeading(trimmed) {
                blocks.append(.heading(id: nextId("h\(heading.level)"), level: heading.level, text: heading.text))
                i += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let qt = lines[i].trimmingCharacters(in: .whitespaces)
                    if qt.hasPrefix(">") {
                        var content = String(qt.dropFirst())
                        if content.hasPrefix(" ") { content.removeFirst() }
                        quoteLines.append(content)
                        i += 1
                    } else if qt.isEmpty {
                        break
                    } else {
                        break
                    }
                }
                blocks.append(.blockquote(id: nextId("quote"), lines: quoteLines))
                continue
            }

            // GFM Table (header + separator row)
            if i + 1 < lines.count,
               line.contains("|"),
               let alignments = parseTableSeparator(lines[i + 1]) {
                let headers = splitTableRow(line)
                i += 2
                var rows: [[String]] = []
                while i < lines.count {
                    let rowLine = lines[i]
                    let rowTrimmed = rowLine.trimmingCharacters(in: .whitespaces)
                    if rowTrimmed.isEmpty || !rowLine.contains("|") {
                        break
                    }
                    var cells = splitTableRow(rowLine)
                    if cells.count < headers.count {
                        cells.append(contentsOf: Array(repeating: "", count: headers.count - cells.count))
                    } else if cells.count > headers.count {
                        cells = Array(cells.prefix(headers.count))
                    }
                    rows.append(cells)
                    i += 1
                }
                let normalizedAlignments = (0..<headers.count).map { idx in
                    idx < alignments.count ? alignments[idx] : MarkdownBlock.TableAlignment.leading
                }
                blocks.append(.table(
                    id: nextId("tbl"),
                    headers: headers,
                    alignments: normalizedAlignments,
                    rows: rows
                ))
                continue
            }

            // Checklist (- [x] / - [ ])
            if parseChecklistLine(line) != nil {
                var items: [MarkdownBlock.ChecklistEntry] = []
                var itemIndex = 0
                while i < lines.count, let parsed = parseChecklistLine(lines[i]) {
                    items.append(.init(
                        id: "chk-\(blockSeq)-\(itemIndex)",
                        checked: parsed.checked,
                        indent: parsed.indent,
                        text: parsed.text
                    ))
                    itemIndex += 1
                    i += 1
                }
                blocks.append(.checklist(id: nextId("chk"), items: items))
                continue
            }

            // Unordered list
            if parseUnorderedListLine(line) != nil {
                var items: [MarkdownBlock.ListEntry] = []
                var itemIndex = 0
                while i < lines.count {
                    if parseChecklistLine(lines[i]) != nil { break }
                    guard let parsed = parseUnorderedListLine(lines[i]) else { break }
                    items.append(.init(
                        id: "ul-\(blockSeq)-\(itemIndex)",
                        index: itemIndex + 1,
                        indent: parsed.indent,
                        text: parsed.text
                    ))
                    itemIndex += 1
                    i += 1
                }
                blocks.append(.list(id: nextId("ul"), ordered: false, items: items))
                continue
            }

            // Ordered list
            if parseOrderedListLine(line) != nil {
                var items: [MarkdownBlock.ListEntry] = []
                var itemIndex = 0
                while i < lines.count, let parsed = parseOrderedListLine(lines[i]) {
                    items.append(.init(
                        id: "ol-\(blockSeq)-\(itemIndex)",
                        index: parsed.number,
                        indent: parsed.indent,
                        text: parsed.text
                    ))
                    itemIndex += 1
                    i += 1
                }
                blocks.append(.list(id: nextId("ol"), ordered: true, items: items))
                continue
            }

            // Paragraph (accumulate contiguous plain lines)
            var paraLines: [String] = [trimmed]
            i += 1
            while i < lines.count {
                let nextLine = lines[i]
                let nextTrimmed = nextLine.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty
                    || nextTrimmed.hasPrefix("```")
                    || nextTrimmed.hasPrefix("~~~")
                    || nextTrimmed.hasPrefix(">")
                    || isThematicBreak(nextTrimmed)
                    || parseHeading(nextTrimmed) != nil
                    || parseChecklistLine(nextLine) != nil
                    || parseUnorderedListLine(nextLine) != nil
                    || parseOrderedListLine(nextLine) != nil {
                    break
                }
                if i + 1 < lines.count,
                   nextLine.contains("|"),
                   parseTableSeparator(lines[i + 1]) != nil {
                    break
                }
                paraLines.append(nextTrimmed)
                i += 1
            }
            blocks.append(.paragraph(id: nextId("p"), text: paraLines.joined(separator: " ")))
        }

        return blocks
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        let stripped = trimmed.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        let first = stripped.first!
        guard first == "-" || first == "*" || first == "_" else { return false }
        return stripped.allSatisfy { $0 == first }
    }

    private static func parseHeading(_ trimmed: String) -> (level: Int, text: String)? {
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard hashes >= 1, hashes <= 6 else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.first == " " || rest.first == "\t" else { return nil }
        let title = rest.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
        return (level: min(hashes, 4), text: title)
    }

    private static func leadingIndentLevel(_ line: String) -> Int {
        var spaces = 0
        for ch in line {
            if ch == " " { spaces += 1 }
            else if ch == "\t" { spaces += 4 }
            else { break }
        }
        return min(spaces / 2, 4)
    }

    private static func parseChecklistLine(_ line: String) -> (checked: Bool, indent: Int, text: String)? {
        let indent = leadingIndentLevel(line)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 6 else { return nil }
        let prefixes: [(String, Bool)] = [
            ("- [x] ", true), ("- [X] ", true), ("- [ ] ", false),
            ("* [x] ", true), ("* [X] ", true), ("* [ ] ", false),
            ("+ [x] ", true), ("+ [X] ", true), ("+ [ ] ", false),
        ]
        for (prefix, checked) in prefixes {
            if trimmed.hasPrefix(prefix) {
                return (checked: checked, indent: indent, text: String(trimmed.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    private static func parseUnorderedListLine(_ line: String) -> (indent: Int, text: String)? {
        let indent = leadingIndentLevel(line)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["- ", "* ", "+ "] {
            if trimmed.hasPrefix(prefix) {
                return (indent: indent, text: String(trimmed.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    private static func parseOrderedListLine(_ line: String) -> (number: Int, indent: Int, text: String)? {
        let indent = leadingIndentLevel(line)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, let num = Int(digits) else { return nil }
        let afterDigits = trimmed.dropFirst(digits.count)
        guard afterDigits.hasPrefix(". ") || afterDigits.hasPrefix(") ") else { return nil }
        return (number: num, indent: indent, text: String(afterDigits.dropFirst(2)))
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var working = line.trimmingCharacters(in: .whitespaces)
        if working.hasPrefix("|") { working.removeFirst() }
        if working.hasSuffix("|") { working.removeLast() }
        return working
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseTableSeparator(_ line: String) -> [MarkdownBlock.TableAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") && trimmed.contains("-") else { return nil }
        let cells = splitTableRow(trimmed)
        guard !cells.isEmpty else { return nil }
        var alignments: [MarkdownBlock.TableAlignment] = []
        for cell in cells {
            let clean = cell.trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty else { return nil }
            let startsColon = clean.hasPrefix(":")
            let endsColon = clean.hasSuffix(":")
            let core = clean.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard core.count >= 2, core.allSatisfy({ $0 == "-" }) else { return nil }
            if startsColon && endsColon {
                alignments.append(.center)
            } else if endsColon {
                alignments.append(.trailing)
            } else {
                alignments.append(.leading)
            }
        }
        return alignments
    }
}

// MARK: - SwiftUI Markdown Renderer View

struct MarkdownRendererView: View {
    let markdown: String
    var collapseSectionsByDefault: Bool = false

    private var document: MarkdownDocument {
        MarkdownParser.parse(markdown)
    }

    var body: some View {
        let doc = document
        if doc.frontmatter.isEmpty && doc.leadingBlocks.isEmpty && doc.sections.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                Text("Empty document")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 80)
        } else {
            LazyVStack(alignment: .leading, spacing: 10) {
                if !doc.frontmatter.isEmpty {
                    FrontmatterBar(entries: doc.frontmatter)
                }

                ForEach(doc.leadingBlocks) { block in
                    MarkdownBlockView(block: block)
                }

                ForEach(doc.sections) { section in
                    CollapsibleH2Section(
                        section: section,
                        initiallyExpanded: !collapseSectionsByDefault
                    )
                }
            }
            .textSelection(.enabled)
        }
    }
}

// MARK: - Frontmatter Strip

private struct FrontmatterBar: View {
    let entries: [(key: String, value: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.key)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                    Text(entry.value)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(2)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

// MARK: - Collapsible H2 Section

private struct CollapsibleH2Section: View {
    let section: MarkdownSection
    @State private var isExpanded: Bool

    init(section: MarkdownSection, initiallyExpanded: Bool) {
        self.section = section
        self._isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(section.blocks) { block in
                    MarkdownBlockView(block: block)
                }
            }
            .padding(.top, 6)
            .padding(.leading, 4)
        } label: {
            HStack(spacing: 6) {
                InlineMarkdownText(section.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                if !isExpanded && !section.blocks.isEmpty {
                    Text("\(section.blocks.count) blocks")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            }
        }
        .padding(.top, 4)
    }
}

// MARK: - Block View

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(_, let level, let text):
            headingView(level: level, text: text)

        case .paragraph(_, let text):
            InlineMarkdownText(text)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)

        case .codeBlock(_, let language, let code):
            MarkdownCodeBlockView(language: language, code: code)

        case .checklist(_, let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: item.checked ? "checkmark.square.fill" : "square")
                            .font(.system(size: 12))
                            .foregroundStyle(item.checked ? Color.green : Color.secondary)
                        InlineMarkdownText(item.text)
                            .font(.system(size: 12.5))
                            .strikethrough(item.checked, color: .secondary.opacity(0.7))
                            .foregroundStyle(item.checked ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.indent) * 14)
                }
            }

        case .list(_, let ordered, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(item.index)." : "•")
                            .font(.system(size: 12, weight: .medium, design: ordered ? .monospaced : .default))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: ordered ? 18 : 10, alignment: .trailing)
                        InlineMarkdownText(item.text)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.primary.opacity(0.92))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.indent) * 14)
                }
            }

        case .blockquote(_, let lines):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        if line.isEmpty {
                            Spacer().frame(height: 3)
                        } else {
                            InlineMarkdownText(line)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))

        case .table(_, let headers, let alignments, let rows):
            MarkdownTableView(headers: headers, alignments: alignments, rows: rows)

        case .thematicBreak:
            Divider()
                .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func headingView(level: Int, text: String) -> some View {
        switch level {
        case 1:
            VStack(alignment: .leading, spacing: 4) {
                InlineMarkdownText(text)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.primary)
                Divider()
            }
            .padding(.top, 2)
        case 2:
            InlineMarkdownText(text)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.top, 4)
        case 3:
            InlineMarkdownText(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.95))
                .padding(.top, 3)
        default:
            InlineMarkdownText(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.top, 2)
        }
    }
}

// MARK: - Code Block View with 1-Click Copy

private struct MarkdownCodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(language?.lowercased() ?? "code")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    copyToPasteboard()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        Text(copied ? "Copied" : "Copy")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(copied ? Color.green : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.04))

            Divider().opacity(0.5)

            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.92))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.75)
        )
    }

    private func copyToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) {
            copied = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeInOut(duration: 0.15)) {
                copied = false
            }
        }
    }
}

// MARK: - GFM Table View

private struct MarkdownTableView: View {
    let headers: [String]
    let alignments: [MarkdownBlock.TableAlignment]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { col, header in
                        InlineMarkdownText(header)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(alignment(for: col).textAlignment)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(minWidth: 72, maxWidth: .infinity, alignment: alignment(for: col).swiftUIAlignment)
                            .background(Color.primary.opacity(0.06))
                    }
                }

                Divider()
                    .gridCellUnsizedAxes(.horizontal)

                ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { col, cell in
                            InlineMarkdownText(cell)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.primary.opacity(0.9))
                                .multilineTextAlignment(alignment(for: col).textAlignment)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .frame(minWidth: 72, maxWidth: .infinity, alignment: alignment(for: col).swiftUIAlignment)
                                .background(rowIdx.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025))
                        }
                    }
                    if rowIdx < rows.count - 1 {
                        Divider()
                            .opacity(0.5)
                            .gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.75)
            )
        }
    }

    private func alignment(for col: Int) -> MarkdownBlock.TableAlignment {
        col < alignments.count ? alignments[col] : .leading
    }
}

// MARK: - Inline Markdown Text

struct InlineMarkdownText: View {
    let raw: String

    init(_ raw: String) {
        self.raw = raw
    }

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            Text(attributed)
        } else {
            Text(raw)
        }
    }
}
