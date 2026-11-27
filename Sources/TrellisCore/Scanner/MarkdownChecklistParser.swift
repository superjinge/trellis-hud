import Foundation

/// Parses real Markdown checklists (`- [x]` / `- [ ]`), YAML frontmatter `paths:` globs,
/// and human-readable PRD excerpts from Trellis documents.
public enum MarkdownChecklistParser: Sendable {
    private static let skippedMetaPrefixes: [String] = [
        "parent:", "project:", "created:", "updated:", "status:", "branch:", "id:",
        "状态:", "状态：", "进度:", "进度：", "父任务:", "父任务：", "项目:", "项目：", "分支:", "分支：",
    ]

    /// Parses all Markdown task-list checkboxes (`- [x]`, `- [X]`, `- [ ]`, `* [ ]`, `+ [x]`)
    /// from `markdown`, ignoring checkboxes inside fenced code blocks and preserving current heading sections.
    public static func parseChecklists(markdown: String, sourceFile: String) -> [ChecklistItem] {
        var items: [ChecklistItem] = []
        var currentSection: String?
        var inFence = false
        var activeFenceMarker: Character = "`"

        let lines = markdown.components(separatedBy: .newlines)
        for (index, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if let fenceChar = fenceCharacter(for: trimmed) {
                if !inFence {
                    inFence = true
                    activeFenceMarker = fenceChar
                } else if fenceChar == activeFenceMarker {
                    inFence = false
                }
                continue
            }

            if inFence {
                continue
            }

            if let heading = parseHeading(trimmed) {
                currentSection = heading
                continue
            }

            if let parsed = parseCheckboxLine(trimmed) {
                let lineNumber = index + 1
                items.append(
                    ChecklistItem(
                        id: "\(sourceFile):\(lineNumber)",
                        text: parsed.text,
                        isCompleted: parsed.isCompleted,
                        sourceFile: sourceFile,
                        lineNumber: lineNumber,
                        section: currentSection
                    )
                )
            }
        }

        return items
    }

    /// Parses combined execution & acceptance checklists from `implement.md` and `prd.md` inside `taskDir`.
    public static func parseTaskChecklists(taskDir: String) -> [ChecklistItem] {
        let baseURL = URL(fileURLWithPath: taskDir, isDirectory: true)
        var combined: [ChecklistItem] = []

        for fileName in ["implement.md", "prd.md"] {
            let fileURL = baseURL.appendingPathComponent(fileName)
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }
            combined.append(contentsOf: parseChecklists(markdown: content, sourceFile: fileName))
        }

        return combined
    }

    /// Extracts `paths:` glob patterns from YAML frontmatter of a Trellis spec Markdown document.
    /// Supports both inline flow arrays (`paths: [a, b]`) and block lists (`- glob`).
    public static func extractFrontmatterPaths(markdown: String) -> [String] {
        let lines = markdown.components(separatedBy: .newlines)
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces), first == "---" else {
            return []
        }

        var inPaths = false
        var results: [String] = []
        var seen = Set<String>()

        func appendPath(_ raw: String) {
            let cleaned = stripWrappingQuotes(raw.trimmingCharacters(in: .whitespaces))
            guard !cleaned.isEmpty else { return }
            if seen.insert(cleaned).inserted {
                results.append(cleaned)
            }
        }

        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." {
                break
            }

            if trimmed.hasPrefix("paths:") {
                let rest = String(trimmed.dropFirst("paths:".count)).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("[") && rest.hasSuffix("]") {
                    let inner = String(rest.dropFirst().dropLast())
                    for item in inner.split(separator: ",") {
                        appendPath(String(item))
                    }
                    inPaths = false
                } else if !rest.isEmpty && !rest.hasPrefix("#") {
                    appendPath(rest)
                    inPaths = false
                } else {
                    inPaths = true
                }
                continue
            }

            if inPaths {
                if trimmed.isEmpty || trimmed.hasPrefix("#") {
                    continue
                }
                if trimmed.hasPrefix("- ") {
                    let value = String(trimmed.dropFirst(2))
                    let withoutComment = stripInlineYAMLComment(value)
                    appendPath(withoutComment)
                } else if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                    inPaths = false
                } else {
                    inPaths = false
                }
            }
        }

        return results
    }

    /// Extracts the first meaningful body paragraph or bullet summary from a PRD document.
    public static func extractExcerpt(markdown: String, maxLength: Int = 360) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        var startIndex = 0

        if let first = lines.first?.trimmingCharacters(in: .whitespaces), first == "---" {
            for idx in 1..<lines.count {
                let t = lines[idx].trimmingCharacters(in: .whitespaces)
                if t == "---" || t == "..." {
                    startIndex = idx + 1
                    break
                }
            }
        }

        var output = ""
        var started = false
        var previousWasBullet = false
        var inFence = false

        for idx in startIndex..<lines.count {
            let t = lines[idx].trimmingCharacters(in: .whitespaces)

            if fenceCharacter(for: t) != nil {
                inFence.toggle()
                if started { break }
                continue
            }
            if inFence { continue }

            if t.isEmpty {
                if started { break }
                continue
            }

            if t.hasPrefix("#") || t.hasPrefix(">") || t == "---" || t == "***" || t.hasPrefix("<!--") {
                if started { break }
                continue
            }

            let metaProbe = t.trimmingCharacters(in: CharacterSet(charactersIn: "-*+ ")).lowercased()
            if skippedMetaPrefixes.contains(where: { metaProbe.hasPrefix($0) }) {
                if started { break }
                continue
            }

            let (body, isBullet) = stripBulletPrefix(t)
            guard !body.isEmpty else { continue }

            if started {
                if previousWasBullet || isBullet {
                    output.append("；")
                } else if shouldInsertSpace(between: output, and: body) {
                    output.append(" ")
                }
            }

            output.append(body)
            started = true
            previousWasBullet = isBullet

            if output.count > maxLength {
                break
            }
        }

        if output.count > maxLength {
            let prefix = String(output.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
            return prefix + "…"
        }
        return output
    }

    // MARK: - Private Helpers

    private static func fenceCharacter(for trimmedLine: String) -> Character? {
        if trimmedLine.hasPrefix("```") { return "`" }
        if trimmedLine.hasPrefix("~~~") { return "~" }
        return nil
    }

    private static func parseHeading(_ trimmedLine: String) -> String? {
        guard trimmedLine.hasPrefix("#") else { return nil }
        var hashes = 0
        for ch in trimmedLine {
            if ch == "#" { hashes += 1 } else { break }
        }
        guard hashes >= 1, hashes <= 6 else { return nil }
        let rest = trimmedLine.dropFirst(hashes)
        guard rest.first == " " || rest.first == "\t" else { return nil }
        let title = rest.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    private static func parseCheckboxLine(_ trimmedLine: String) -> (isCompleted: Bool, text: String)? {
        guard trimmedLine.count >= 5 else { return nil }
        let first = trimmedLine[trimmedLine.startIndex]
        guard first == "-" || first == "*" || first == "+" else { return nil }

        let afterBullet = trimmedLine.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
        guard afterBullet.count >= 3 else { return nil }

        let i0 = afterBullet.startIndex
        let i1 = afterBullet.index(after: i0)
        let i2 = afterBullet.index(after: i1)
        guard afterBullet[i0] == "[", afterBullet[i2] == "]" else { return nil }

        let mark = afterBullet[i1]
        let isCompleted: Bool
        switch mark {
        case "x", "X":
            isCompleted = true
        case " ":
            isCompleted = false
        default:
            return nil
        }

        let afterBracket = afterBullet.index(after: i2)
        if afterBracket < afterBullet.endIndex {
            let sep = afterBullet[afterBracket]
            guard sep == " " || sep == "\t" else { return nil }
        }

        let text = String(afterBullet[afterBracket...]).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (isCompleted, text)
    }

    private static func stripBulletPrefix(_ line: String) -> (String, Bool) {
        if let parsed = parseCheckboxLine(line) {
            return (parsed.text, true)
        }
        if let first = line.first, first == "-" || first == "*" || first == "+" {
            let rest = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty {
                return (rest, true)
            }
        }
        // Ordered list: `1. text`
        var digits = 0
        for ch in line {
            if ch.isASCII && ch.isNumber { digits += 1 } else { break }
        }
        if digits > 0 {
            let afterDigits = line.dropFirst(digits)
            if afterDigits.hasPrefix(". ") {
                let rest = String(afterDigits.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                return (rest, true)
            }
        }
        return (line, false)
    }

    private static func shouldInsertSpace(between lhs: String, and rhs: String) -> Bool {
        guard let last = lhs.last, let first = rhs.first else { return false }
        return (last.isASCII && (last.isLetter || last.isNumber))
            && (first.isASCII && (first.isLetter || first.isNumber))
    }

    private static func stripWrappingQuotes(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func stripInlineYAMLComment(_ value: String) -> String {
        var inSingle = false
        var inDouble = false
        var idx = value.startIndex
        while idx < value.endIndex {
            let ch = value[idx]
            if ch == "'" && !inDouble { inSingle.toggle() }
            else if ch == "\"" && !inSingle { inDouble.toggle() }
            else if ch == "#" && !inSingle && !inDouble {
                return String(value[..<idx]).trimmingCharacters(in: .whitespaces)
            }
            idx = value.index(after: idx)
        }
        return value.trimmingCharacters(in: .whitespaces)
    }
}
