import XCTest
@testable import PetChat

final class MarkdownTextTests: XCTestCase {
    func testHeadingStripsHashes() {
        XCTAssertEqual(MarkdownBlock.parse("### Title"), [.heading(level: 3, text: "Title")])
        XCTAssertEqual(MarkdownBlock.parse("# A"), [.heading(level: 1, text: "A")])
        XCTAssertEqual(MarkdownBlock.parse("#NoSpace"), [.paragraph("#NoSpace")])
    }

    func testBullets() {
        XCTAssertEqual(MarkdownBlock.parse("- a\n* b\n+ c"), [.bullet("a"), .bullet("b"), .bullet("c")])
    }

    func testNumbered() {
        XCTAssertEqual(MarkdownBlock.parse("1. one\n2) two"), [.numbered(1, "one"), .numbered(2, "two")])
    }

    func testClosedFencedCodeIgnoresLanguageAndKeepsMarkdownLiteral() {
        XCTAssertEqual(MarkdownBlock.parse("```swift\nlet x = 1\n# not heading\n```\nafter"),
                       [.code("let x = 1\n# not heading"), .paragraph("after")])
    }

    func testUnclosedFenceRendersRestAsCode() {
        XCTAssertEqual(MarkdownBlock.parse("intro\n```\nlet x\n- y"), [.paragraph("intro"), .code("let x\n- y")])
    }

    func testParagraphLinesJoinAndBlankLinesSeparate() {
        XCTAssertEqual(MarkdownBlock.parse("a\nb\n\nc"), [.paragraph("a\nb"), .paragraph("c")])
    }

    func testQuoteStripsMarker() {
        XCTAssertEqual(MarkdownBlock.parse("> hi\n> there"), [.quote("hi\nthere")])
    }

    func testRules() {
        XCTAssertEqual(MarkdownBlock.parse("a\n---\n***"), [.paragraph("a"), .rule, .rule])
    }
}
