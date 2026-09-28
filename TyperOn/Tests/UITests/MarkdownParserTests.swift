// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import SwiftUI
import Testing
@testable import Typer_On

@Suite("MarkdownParser")
struct MarkdownParserTests {

    @Test @MainActor func unchangedInlineMarkdownRestylesWithoutReparsing() throws {
        let cache = MarkdownTextCache<AttributedString>()
        let text = "Keep **bold**, `inline code` and [link](https://example.com)."
        var parseCount = 0
        let parse: (String) -> AttributedString = { text in
            parseCount += 1
            return MarkdownInlineRenderer.parseSyntax(text)
        }
        let syntax = cache.value(for: text, parse: parse)
        func rgba(_ color: Color, appearance: NSAppearance) -> [CGFloat]? {
            var components: [CGFloat]?
            appearance.performAsCurrentDrawingAppearance {
                if let resolved = NSColor(color).usingColorSpace(.deviceRGB) {
                    components = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent, resolved.alphaComponent]
                }
            }
            return components
        }

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: appearanceName))
            var codeBackgrounds: [[CGFloat]] = []
            for style in SelectionTriggerStyle.allCases {
                let theme = DialogTheme(style: style)
                let cached = cache.value(for: text, parse: parse)
                let rendered = MarkdownInlineRenderer.styled(cached, theme: theme)
                #expect(String(rendered.characters) == String(syntax.characters))
                #expect(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
                #expect(rendered.runs.contains { $0.link?.absoluteString == "https://example.com" })
                guard let code = rendered.runs.first(where: { $0.inlinePresentationIntent?.contains(.code) == true }) else {
                    Issue.record("Expected inline code run")
                    return
                }
                let foreground = try #require(code.foregroundColor)
                let background = try #require(code.backgroundColor)
                let foregroundRGBA = try #require(rgba(foreground, appearance: appearance))
                let backgroundRGBA = try #require(rgba(background, appearance: appearance))
                #expect(foregroundRGBA == rgba(theme.textPrimary, appearance: appearance))
                #expect(backgroundRGBA == rgba(theme.codeInlineBackground, appearance: appearance))
                #expect(code.font == .system(size: 12, design: .monospaced))
                codeBackgrounds.append(backgroundRGBA)
                // Styling copies the cached syntax; it must never freeze a previous palette.
                #expect(cached.runs.allSatisfy { $0.foregroundColor == nil && $0.backgroundColor == nil && $0.font == nil })
            }
            #expect(codeBackgrounds.first != codeBackgrounds.last)
        }

        #expect(parseCount == 1)
        #expect(cache.value(for: text, parse: parse) == syntax)
        #expect(parseCount == 1)
    }

    @Test @MainActor func cachedMessageReusesParseUntilItsTextChanges() {
        let cache = MarkdownTextCache<[MarkdownBlock]>()
        var parseCount = 0
        let parse: (String) -> [MarkdownBlock] = { text in
            parseCount += 1
            return MarkdownParser.parse(text)
        }
        let original = cache.value(for: "# Heading", parse: parse)
        let reused = cache.value(for: "# Heading", parse: parse)
        #expect(parseCount == 1)
        #expect(original.count == reused.count)
        let updated = cache.value(for: "# Heading\n\nNew paragraph", parse: parse)
        #expect(parseCount == 2)
        #expect(updated.count == 2)
        _ = cache.value(for: "# Heading", parse: parse)
        #expect(parseCount == 3)
    }

    @Test func parsesPlainText() {
        let blocks = MarkdownParser.parse("Hello, world!")
        #expect(blocks.count == 1)
        guard case .prose(let text) = blocks[0].kind else {
            Issue.record("Expected prose block")
            return
        }
        #expect(text == "Hello, world!")
    }

    @Test func parsesEmptyInput() {
        let blocks = MarkdownParser.parse("")
        #expect(blocks.isEmpty)
    }

    @Test func parsesSingleCodeBlock() {
        let input = """
        ```
        let x = 1
        ```
        """
        let blocks = MarkdownParser.parse(input)
        #expect(blocks.count == 1)
        guard case .codeBlock(let language, let code) = blocks[0].kind else {
            Issue.record("Expected code block")
            return
        }
        #expect(language == nil)
        #expect(code == "let x = 1")
    }

    @Test func parsesCodeBlockWithLanguage() {
        let input = """
        ```swift
        let x = 1
        ```
        """
        let blocks = MarkdownParser.parse(input)
        #expect(blocks.count == 1)
        guard case .codeBlock(let language, let code) = blocks[0].kind else {
            Issue.record("Expected code block")
            return
        }
        #expect(language == "swift")
        #expect(code == "let x = 1")
    }

    @Test func parsesMultipleBlocks() {
        let input = """
        Here is some code:

        ```python
        print("hello")
        ```

        And some more text.
        """
        let blocks = MarkdownParser.parse(input)
        #expect(blocks.count == 3)

        guard case .prose(let before) = blocks[0].kind else {
            Issue.record("Expected prose block at 0")
            return
        }
        #expect(before.contains("Here is some code:"))

        guard case .codeBlock(let lang, let code) = blocks[1].kind else {
            Issue.record("Expected code block at 1")
            return
        }
        #expect(lang == "python")
        #expect(code == "print(\"hello\")")

        guard case .prose(let after) = blocks[2].kind else {
            Issue.record("Expected prose block at 2")
            return
        }
        #expect(after.contains("And some more text."))
    }

    @Test func handlesUnclosedCodeBlockDuringStreaming() {
        let input = """
        Here is code:
        ```swift
        let x = 1
        let y = 2
        """
        let blocks = MarkdownParser.parse(input)
        #expect(blocks.count == 2)

        guard case .prose = blocks[0].kind else {
            Issue.record("Expected prose block at 0")
            return
        }

        guard case .codeBlock(let lang, let code) = blocks[1].kind else {
            Issue.record("Expected code block at 1")
            return
        }
        #expect(lang == "swift")
        #expect(code == "let x = 1\nlet y = 2")
    }

    @Test func handlesConsecutiveCodeBlocks() {
        let input = """
        ```js
        console.log("a")
        ```
        ```py
        print("b")
        ```
        """
        let blocks = MarkdownParser.parse(input)
        #expect(blocks.count == 2)

        guard case .codeBlock(let lang1, _) = blocks[0].kind else {
            Issue.record("Expected code block at 0")
            return
        }
        #expect(lang1 == "js")

        guard case .codeBlock(let lang2, _) = blocks[1].kind else {
            Issue.record("Expected code block at 1")
            return
        }
        #expect(lang2 == "py")
    }

    @Test func stableBlockIDsAcrossGrowingText() {
        let partial = """
        Hello
        ```swift
        let x
        """
        let full = """
        Hello
        ```swift
        let x = 1
        ```
        Done
        """
        let partialBlocks = MarkdownParser.parse(partial)
        let fullBlocks = MarkdownParser.parse(full)

        #expect(partialBlocks[0].id == fullBlocks[0].id)
        #expect(partialBlocks[1].id == fullBlocks[1].id)
    }

    @Test func ignoresInlineBackticksAsFenceOpeners() {
        let input = "Use `let x = 1` for inline code"
        let blocks = MarkdownParser.parse(input)
        #expect(blocks.count == 1)
        guard case .prose = blocks[0].kind else {
            Issue.record("Expected prose block")
            return
        }
    }

    @Test func handlesCodeBlockAtEnd() {
        let input = """
        Text before
        ```
        code here
        ```
        """
        let blocks = MarkdownParser.parse(input)
        #expect(blocks.count == 2)
        guard case .prose = blocks[0].kind else {
            Issue.record("Expected prose at 0")
            return
        }
        guard case .codeBlock(_, let code) = blocks[1].kind else {
            Issue.record("Expected code block at 1")
            return
        }
        #expect(code == "code here")
    }

    @Test func handlesMultilineCodeBlock() {
        let input = """
        ```
        line 1
        line 2
        line 3
        ```
        """
        let blocks = MarkdownParser.parse(input)
        #expect(blocks.count == 1)
        guard case .codeBlock(_, let code) = blocks[0].kind else {
            Issue.record("Expected code block")
            return
        }
        #expect(code == "line 1\nline 2\nline 3")
    }

    @Test func parsesHeadingBlock() {
        let blocks = MarkdownParser.parse("### Title")
        #expect(blocks.count == 1)
        guard case .heading(let level, let text) = blocks[0].kind else {
            Issue.record("Expected heading block")
            return
        }
        #expect(level == 3)
        #expect(text == "Title")
    }

    @Test func parsesMixedHeadingAndProseBlocks() {
        let input = """
        ## Title

        Paragraph text
        """
        let blocks = MarkdownParser.parse(input)
        #expect(blocks.count == 2)

        guard case .heading(let level, let text) = blocks[0].kind else {
            Issue.record("Expected heading block at 0")
            return
        }
        #expect(level == 2)
        #expect(text == "Title")

        guard case .prose(let text) = blocks[1].kind else {
            Issue.record("Expected prose block at 1")
            return
        }
        #expect(text == "Paragraph text")
    }

    @Test func parsesUnorderedListAsSingleBlock() {
        let input = """
        - First item
        - Second item
        - Third item
        """
        let blocks = MarkdownParser.parse(input)
        #expect(blocks.count == 1)

        guard case .unorderedList(let items) = blocks[0].kind else {
            Issue.record("Expected unordered list block")
            return
        }
        #expect(items == ["First item", "Second item", "Third item"])
    }

    @Test func parsesListMarkersStarAndPlus() {
        let input = """
        * First item
        + Second item
        """
        let blocks = MarkdownParser.parse(input)
        #expect(blocks.count == 1)

        guard case .unorderedList(let items) = blocks[0].kind else {
            Issue.record("Expected unordered list block")
            return
        }
        #expect(items == ["First item", "Second item"])
    }

    @Test func parsesBlockquoteSingleAndMultiline() {
        let input = """
        > First line
        > Second line
        """
        let blocks = MarkdownParser.parse(input)
        #expect(blocks.count == 1)

        guard case .blockquote(let text) = blocks[0].kind else {
            Issue.record("Expected blockquote block")
            return
        }
        #expect(text == "First line\nSecond line")
    }

    @Test func keepsCodeFencePriorityOverHeadingListQuoteMarkers() {
        let input = """
        ```
        # Title
        - List item
        > Quote
        ```
        """
        let blocks = MarkdownParser.parse(input)
        #expect(blocks.count == 1)

        guard case .codeBlock(_, let code) = blocks[0].kind else {
            Issue.record("Expected code block")
            return
        }
        #expect(code == "# Title\n- List item\n> Quote")
    }

    @Test func stableBlockIDsAcrossGrowingListOrQuoteDuringStreaming() {
        let partialList = """
        - First item
        """
        let fullList = """
        - First item
        - Second item
        """

        let partialListBlocks = MarkdownParser.parse(partialList)
        let fullListBlocks = MarkdownParser.parse(fullList)

        #expect(partialListBlocks.count == 1)
        #expect(fullListBlocks.count == 1)
        #expect(partialListBlocks[0].id == fullListBlocks[0].id)

        let partialQuote = """
        > First line
        """
        let fullQuote = """
        > First line
        > Second line
        """

        let partialQuoteBlocks = MarkdownParser.parse(partialQuote)
        let fullQuoteBlocks = MarkdownParser.parse(fullQuote)

        #expect(partialQuoteBlocks.count == 1)
        #expect(fullQuoteBlocks.count == 1)
        #expect(partialQuoteBlocks[0].id == fullQuoteBlocks[0].id)
    }

    @Test func parsesMixedHeadingListQuoteCodeSequence() {
        let input = """
        # Heading

        - Item one
        - Item two

        > Quoted text

        ```swift
        let x = 1
        ```

        Tail prose
        """
        let blocks = MarkdownParser.parse(input)
        #expect(blocks.count == 5)

        guard case .heading(let level, let headingText) = blocks[0].kind else {
            Issue.record("Expected heading block at 0")
            return
        }
        #expect(level == 1)
        #expect(headingText == "Heading")

        guard case .unorderedList(let items) = blocks[1].kind else {
            Issue.record("Expected list block at 1")
            return
        }
        #expect(items == ["Item one", "Item two"])

        guard case .blockquote(let quoteText) = blocks[2].kind else {
            Issue.record("Expected blockquote block at 2")
            return
        }
        #expect(quoteText == "Quoted text")

        guard case .codeBlock(let language, let code) = blocks[3].kind else {
            Issue.record("Expected code block at 3")
            return
        }
        #expect(language == "swift")
        #expect(code == "let x = 1")

        guard case .prose(let proseText) = blocks[4].kind else {
            Issue.record("Expected prose block at 4")
            return
        }
        #expect(proseText == "Tail prose")
    }
}
