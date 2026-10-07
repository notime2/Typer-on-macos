// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation

struct MarkdownBlock: Identifiable, Sendable {
    let id: Int
    let kind: Kind

    enum Kind: Sendable {
        case prose(String)
        case heading(level: Int, text: String)
        case unorderedList(items: [String])
        case blockquote(text: String)
        case codeBlock(language: String?, code: String)
    }
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        guard !text.isEmpty else { return [] }

        var blocks: [MarkdownBlock] = []
        var currentProseLines: [String] = []
        var currentCodeLines: [String] = []
        var currentListItems: [String] = []
        var currentBlockquoteLines: [String] = []
        var codeLanguage: String?
        var inCodeBlock = false
        var blockIndex = 0

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        func appendBlock(_ kind: MarkdownBlock.Kind) {
            blocks.append(MarkdownBlock(id: blockIndex, kind: kind))
            blockIndex += 1
        }

        func flushProse() {
            guard !currentProseLines.isEmpty else { return }
            appendBlock(.prose(currentProseLines.joined(separator: "\n")))
            currentProseLines.removeAll(keepingCapacity: true)
        }

        func flushList() {
            guard !currentListItems.isEmpty else { return }
            appendBlock(.unorderedList(items: currentListItems))
            currentListItems.removeAll(keepingCapacity: true)
        }

        func flushBlockquote() {
            guard !currentBlockquoteLines.isEmpty else { return }
            appendBlock(.blockquote(text: currentBlockquoteLines.joined(separator: "\n")))
            currentBlockquoteLines.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if !inCodeBlock && trimmed.hasPrefix("```") {
                flushProse()
                flushList()
                flushBlockquote()
                inCodeBlock = true
                let langPart = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                codeLanguage = langPart.isEmpty ? nil : langPart
                currentCodeLines.removeAll(keepingCapacity: true)
                continue
            }

            if inCodeBlock {
                if trimmed == "```" {
                    appendBlock(.codeBlock(language: codeLanguage, code: currentCodeLines.joined(separator: "\n")))
                    currentCodeLines.removeAll(keepingCapacity: true)
                    codeLanguage = nil
                    inCodeBlock = false
                } else {
                    currentCodeLines.append(line)
                }
                continue
            }

            if let heading = parseHeading(from: trimmed) {
                flushProse()
                flushList()
                flushBlockquote()
                appendBlock(.heading(level: heading.level, text: heading.text))
                continue
            }

            if let listItem = parseListItem(from: trimmed) {
                flushProse()
                flushBlockquote()
                currentListItems.append(listItem)
                continue
            }

            if let blockquoteLine = parseBlockquoteLine(from: trimmed) {
                flushProse()
                flushList()
                currentBlockquoteLines.append(blockquoteLine)
                continue
            }

            if trimmed.isEmpty {
                flushProse()
                flushList()
                flushBlockquote()
                continue
            }

            flushList()
            flushBlockquote()
            currentProseLines.append(line)
        }

        if inCodeBlock {
            appendBlock(.codeBlock(language: codeLanguage, code: currentCodeLines.joined(separator: "\n")))
        } else {
            flushProse()
            flushList()
            flushBlockquote()
        }

        return blocks
    }

    private static func parseHeading(from line: String) -> (level: Int, text: String)? {
        guard !line.isEmpty else { return nil }

        var level = 0
        var index = line.startIndex

        while index < line.endIndex, line[index] == "#", level < 6 {
            level += 1
            index = line.index(after: index)
        }

        guard level > 0 else { return nil }
        guard index == line.endIndex || line[index].isWhitespace else { return nil }

        let text = String(line[index...]).trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    private static func parseListItem(from line: String) -> String? {
        guard line.count >= 2 else { return nil }
        guard let marker = line.first, "-*+".contains(marker) else { return nil }

        let contentStart = line.index(after: line.startIndex)
        guard line[contentStart].isWhitespace else { return nil }

        return String(line[contentStart...]).trimmingCharacters(in: .whitespaces)
    }

    private static func parseBlockquoteLine(from line: String) -> String? {
        guard line.first == ">" else { return nil }

        var content = line.dropFirst()
        if content.first?.isWhitespace == true {
            content = content.dropFirst()
        }

        return String(content)
    }
}
