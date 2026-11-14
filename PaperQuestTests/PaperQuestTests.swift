//
//  PaperQuestTests.swift
//  PaperQuestTests
//
//  Regression tests for PDF → card analysis. Run them after every change to
//  PaperAnalyzer so that layouts that already work keep working.
//

import Foundation
import PDFKit
import Testing
@testable import PaperQuest

// MARK: - Fixtures

/// Test PDFs are read from the repository on the Mac; tests run in the simulator,
/// which can read host paths.
enum Fixture {
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Original demo paper committed to the repository.
    static let demoPaper = repositoryRoot.appending(path: "docs/demo/demo-paper.pdf")

    /// Copyrighted papers kept only on the developer's Mac (see `.gitignore`).
    static let ieeePaper = repositoryRoot.appending(path: "LocalTestPapers/x-spur-ieee.pdf")
    static let neuripsPaper = repositoryRoot.appending(path: "LocalTestPapers/attention-neurips.pdf")

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func cards(from url: URL) throws -> [PaperBlock] {
        PaperAnalyzer.analyze(paper: try PDFImportService.importPaper(from: url))
    }
}

/// A compact, comparable view of the analysis result.
struct CardSummary {
    let cards: [PaperBlock]

    var texts: [TextBlock] { cards.compactMap { if case .text(let b) = $0 { b } else { nil } } }
    var figures: [FigureBlock] { cards.compactMap { if case .figure(let b) = $0, !b.isAlgorithm { b } else { nil } } }
    var algorithms: [FigureBlock] { cards.compactMap { if case .figure(let b) = $0, b.isAlgorithm { b } else { nil } } }
    var tables: [TableBlock] { cards.compactMap { if case .table(let b) = $0 { b } else { nil } } }
    var equations: [EquationBlock] { cards.compactMap { if case .equation(let b) = $0 { b } else { nil } } }
    var title: TitleBlock? { if case .title(let b)? = cards.first { b } else { nil } }

    var sections: [String] {
        var seen: [String] = []
        for section in cards.compactMap(\.section) where !seen.contains(section) {
            seen.append(section)
        }
        return seen
    }

    /// Every piece of text a reader can see or have translated.
    var allText: String {
        cards.map { card in
            switch card {
            case .title(let b): b.title
            case .text(let b): b.original
            case .figure(let b): b.caption
            case .table(let b): b.caption
            case .equation(let b): [b.leadIn, b.extractedEquation, b.followUp].compactMap { $0 }.joined(separator: " ")
            }
        }.joined(separator: "\n")
    }

    var regions: [PDFRegion] {
        cards.flatMap { card -> [PDFRegion] in
            switch card {
            case .title(let b): [b.region]
            case .text(let b): b.regions
            case .figure(let b): [b.region]
            case .table(let b): [b.region]
            case .equation(let b): b.regions
            }
        }
    }
}

/// Every region must lie on its page and be large enough to render.
private func expectValidRegions(_ summary: CardSummary, in url: URL) throws {
    let document = try #require(PDFDocument(url: url))
    for region in summary.regions {
        let page = try #require(document.page(at: region.pageIndex))
        let box = page.bounds(for: .mediaBox)
        #expect(region.rect.width > 10 && region.rect.height > 5, "too small: \(region)")
        #expect(box.insetBy(dx: -8, dy: -8).contains(region.rect), "off page: \(region)")
    }
}

// MARK: - Demo paper (IEEE two-column, committed)

@Suite("Demo paper (IEEE two-column)")
struct DemoPaperTests {
    let summary: CardSummary

    init() throws {
        summary = CardSummary(cards: try Fixture.cards(from: Fixture.demoPaper))
    }

    @Test func cardCountAndOrderStart() throws {
        #expect(summary.cards.count == 21)
        let title = try #require(summary.title)
        #expect(title.title == "Layout-Aware Card Reading of Research Papers on Mobile Devices")
        // The abstract comes right after the title card.
        let abstract = try #require(summary.texts.first)
        #expect(abstract.section == "Abstract")
        #expect(abstract.original.hasPrefix("Abstract—Reading research papers on a phone"))
    }

    @Test func sectionsAreRecognized() {
        #expect(summary.sections == [
            "Abstract",
            "I. Introduction",
            "II. Layout Analysis › A. Lines and Columns",
            "II. Layout Analysis › B. Paragraphs and Headings",
            "II. Layout Analysis › C. Figures, Tables and Equations",
            "III. Card Assembly",
            "IV. Evaluation",
            "V. On-Device Assistance",
            "VI. Conclusion"
        ])
    }

    @Test func visualElementsAreFound() throws {
        let figure = try #require(summary.figures.only)
        #expect(figure.caption.hasPrefix("Fig. 1. Overview of the reading pipeline."))
        #expect(figure.pageNumber == 2)

        let table = try #require(summary.tables.only)
        #expect(table.caption == "TABLE I Share of correctly recovered elements per template")

        let algorithm = try #require(summary.algorithms.only)
        #expect(algorithm.caption == "Algorithm 1 Card assembly")
        // Pseudo-code is kept for the explanation and never leaks into body cards.
        #expect(algorithm.content?.contains("insert each figure after its first mention") == true)
        #expect(!summary.texts.contains { $0.original.contains("end for") })

        let equation = try #require(summary.equations.only)
        #expect(equation.extractedEquation.contains("(1)"))
        #expect(equation.followUp?.hasPrefix("where Q, K and V are the query") == true)
    }

    @Test func listItemsStayWhole() {
        let bullets = summary.texts.filter { $0.original.hasPrefix("•") }
        #expect(bullets.count == 3)
        #expect(bullets.allSatisfy { $0.original.hasSuffix(";") || $0.original.hasSuffix(".") })
    }

    @Test func figureFollowsItsFirstMention() throws {
        let figureIndex = try #require(summary.cards.firstIndex { if case .figure(let b) = $0 { !b.isAlgorithm } else { false } })
        guard case .text(let previous) = summary.cards[figureIndex - 1] else {
            Issue.record("Figure should follow a text card")
            return
        }
        #expect(previous.original.contains("Fig. 1"))
    }

    @Test func noiseIsRemoved() {
        let text = summary.allText
        #expect(!text.contains("PAPERQUEST DEMO PAPER"), "running head")
        #expect(!text.contains("may be freely reused"), "title footnote")
        #expect(!text.contains("Attention is all you need,”"), "reference list")
        #expect(!text.contains("Index Terms"), "keywords")
    }

    @Test func regionsAreValid() throws {
        try expectValidRegions(summary, in: Fixture.demoPaper)
    }
}

// MARK: - Local-only papers

@Suite("IEEE journal paper (local only)", .enabled(if: Fixture.exists(Fixture.ieeePaper)))
struct IEEEPaperTests {
    let summary: CardSummary

    init() throws {
        summary = CardSummary(cards: try Fixture.cards(from: Fixture.ieeePaper))
    }

    @Test func visualElementCounts() {
        #expect(summary.tables.count == 9)
        #expect(summary.figures.count == 4)
        #expect(summary.algorithms.count == 2)
        #expect(summary.equations.count == 12)
    }

    @Test func tableCaptionsAreCompleteAndReal() {
        let labels = summary.tables.map { $0.caption.split(separator: " ").prefix(2).joined(separator: " ") }
        #expect(labels.sorted() == ["TABLE I", "TABLE II", "TABLE III", "TABLE IV", "TABLE IX",
                                    "TABLE V", "TABLE VI", "TABLE VII", "TABLE VIII"])
        // "… summarized in / Table II." inside a sentence is not a caption.
        #expect(!summary.tables.contains { $0.caption.hasPrefix("Table II.") })
        // Header rows must not be swallowed into small-caps titles.
        #expect(summary.tables.contains { $0.caption == "TABLE II ATTACK TYPES IN TOW-IDS" })
    }

    @Test func titleAndSections() throws {
        let title = try #require(summary.title)
        #expect(title.title.hasPrefix("X-SPUR: Explainable Surprisal-Based"))
        let sections = summary.sections
        #expect(sections.first == "Abstract")
        #expect(sections.contains("III. PROBLEM SETUP AND DATA REPRESENTATION › C. BBPE Tokenization and Window Construction"))
        #expect(sections.contains("V. EXPERIMENTAL RESULTS › I. Comparison with Prior Art"))
        #expect(sections.last == "VI. CONCLUSION")
    }

    @Test func noiseIsRemoved() {
        let text = summary.allText
        #expect(!text.contains("IEEE TRANSACTIONS ON INDUSTRIAL INFORMATICS"))
        #expect(!text.contains("accepted for publication"))
        #expect(!text.contains("arXiv:"))
    }

    @Test func equationsKeepTheirContext() {
        // Equation (7): number merged into its line, with lead-in and follow-up.
        let seven = summary.equations.first { $0.extractedEquation.contains("(7)") }
        #expect(seven?.leadIn?.contains("Algorithm 2 summarizes") == true)
        #expect(seven?.followUp?.hasPrefix("where positions corresponding to") == true)
        // Equation (6): sub/superscripts shrink its dominant font size.
        #expect(summary.equations.contains { $0.extractedEquation.contains("(6)") })
    }

    @Test func regionsAreValid() throws {
        try expectValidRegions(summary, in: Fixture.ieeePaper)
    }
}

@Suite("NeurIPS paper (local only)", .enabled(if: Fixture.exists(Fixture.neuripsPaper)))
struct NeurIPSPaperTests {
    let summary: CardSummary

    init() throws {
        summary = CardSummary(cards: try Fixture.cards(from: Fixture.neuripsPaper))
    }

    @Test func visualElementCounts() {
        #expect(summary.tables.count == 4)
        #expect(summary.figures.count == 2)
        #expect(summary.equations.count == 5)
    }

    @Test func titleAbstractAndFootnotes() throws {
        #expect(summary.title?.title == "Attention Is All You Need")
        let abstract = try #require(summary.texts.first)
        #expect(abstract.section == "Abstract")
        #expect(abstract.original.hasPrefix("The dominant sequence transduction models"))
        let text = summary.allText
        #expect(!text.contains("Equal contribution"), "9pt footnote")
        #expect(!text.contains("hereby grants permission"), "notice above the title")
    }

    @Test func bodySizeCaptionsDoNotSwallowTables() {
        let table4 = summary.tables.first { $0.caption.hasPrefix("Table 4:") }
        #expect(table4?.caption.hasSuffix("(Results are on Section 23 of WSJ)") == true)
        #expect(!summary.texts.contains { $0.original.contains("Vinyals & Kaiser") })
    }

    /// A math-heavy line where body text and subscripts have equal character counts.
    /// Font-size ties used to follow randomized dictionary order, so this paragraph
    /// appeared in some runs and vanished in others.
    @Test func mathHeavyLineIsKeptDeterministically() {
        #expect(summary.texts.contains { $0.original.hasPrefix("Where the projections are parameter matrices") })
        // The subscript row inside the equation's height belongs to the equation.
        let multiHead = summary.equations.first { $0.extractedEquation.hasPrefix("MultiHead") }
        #expect(multiHead?.extractedEquation.contains("KWK") == true)
        #expect(multiHead?.followUp == nil)
    }

    @Test func regionsAreValid() throws {
        try expectValidRegions(summary, in: Fixture.neuripsPaper)
    }
}

private extension Array {
    /// The single element, or `nil` when there are zero or several.
    var only: Element? { count == 1 ? first : nil }
}
