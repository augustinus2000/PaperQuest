//
//  PaperModels.swift
//  PaperQuest
//
//  Created by 임준혁 on 7/17/26.
//

import CoreGraphics
import Foundation
import PDFKit

nonisolated struct ImportedPaper {
    let fileName: String
    /// Kept so the analyzer can read line geometry and font sizes.
    let document: PDFDocument
    let pages: [PDFPageContent]
    let completeText: String
}

nonisolated struct PDFPageContent: Identifiable {
    let id = UUID()

    let pageIndex: Int
    let text: String

    var pageNumber: Int {
        pageIndex + 1
    }
}

/// A rectangle on one PDF page, in PDF page coordinates (origin bottom-left).
/// Cards render these regions from the saved PDF so text, math and figures
/// look exactly as typeset.
nonisolated struct PDFRegion: Sendable, Hashable, Identifiable {
    let pageIndex: Int
    let rect: CGRect

    var id: Self {
        self
    }
}

nonisolated enum PaperBlock: Identifiable, Sendable {
    case title(TitleBlock)
    case text(TextBlock)
    case figure(FigureBlock)
    case table(TableBlock)
    case equation(EquationBlock)

    var id: UUID {
        switch self {
        case .title(let block):
            return block.id
        case .text(let block):
            return block.id
        case .figure(let block):
            return block.id
        case .table(let block):
            return block.id
        case .equation(let block):
            return block.id
        }
    }

    var pageNumber: Int {
        switch self {
        case .title(let block):
            return block.pageNumber
        case .text(let block):
            return block.pageNumber
        case .figure(let block):
            return block.pageNumber
        case .table(let block):
            return block.pageNumber
        case .equation(let block):
            return block.pageNumber
        }
    }

    var typeName: String {
        switch self {
        case .title:
            return "논문 정보"
        case .text:
            return "본문"
        case .figure(let block):
            return block.isAlgorithm ? "Algorithm" : "Figure"
        case .table:
            return "Table"
        case .equation:
            return "수식"
        }
    }

    var systemImage: String {
        switch self {
        case .title:
            return "doc.richtext"
        case .text:
            return "doc.text"
        case .figure(let block):
            return block.isAlgorithm ? "list.number" : "photo"
        case .table:
            return "tablecells"
        case .equation:
            return "function"
        }
    }
}

/// Title and author block from the first page, shown as the first card.
nonisolated struct TitleBlock: Sendable {
    let id = UUID()
    let pageNumber: Int
    let title: String
    let region: PDFRegion
}

nonisolated struct TextBlock: Sendable {
    let id = UUID()
    let pageNumber: Int
    /// Section heading the paragraph belongs to, e.g. "IV. PROPOSED FRAMEWORK".
    let section: String?
    /// Extracted text used for translation and explanation.
    let original: String
    /// Preceding paragraph, passed to the explanation model as background only.
    let context: String?
    /// Where the paragraph sits in the PDF; may span columns and pages.
    let regions: [PDFRegion]
}

nonisolated struct FigureBlock: Sendable {
    let id = UUID()
    let pageNumber: Int
    let section: String?
    /// Algorithm boxes are floats like figures and are shown the same way.
    let isAlgorithm: Bool
    let caption: String
    /// Pseudo-code text of an algorithm box; `nil` for figures.
    let content: String?
    /// The paragraph that first mentions this figure, if any.
    let context: String?
    let region: PDFRegion
}

nonisolated struct TableBlock: Sendable {
    let id = UUID()
    let pageNumber: Int
    let section: String?
    let caption: String
    /// The paragraph that first mentions this table, if any.
    let context: String?
    let region: PDFRegion
}

nonisolated struct EquationBlock: Sendable {
    let id = UUID()
    let pageNumber: Int
    let section: String?
    /// PDF text of the equation; often garbled, so cards show `regions` instead.
    let extractedEquation: String
    /// Short sentence introducing the equation ("… the hidden state evolves as").
    let leadIn: String?
    /// Explanation right after the equation ("where α = 1.0 is …").
    let followUp: String?
    /// Neighboring paragraphs, passed to the explanation model as background.
    let surroundingText: String
    /// Lead-in, equation and follow-up regions, in reading order.
    let regions: [PDFRegion]

    /// Prose around the equation, used for translation.
    var prose: String? {
        let parts = [leadIn, followUp].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}

nonisolated extension PaperBlock {
    /// Content and source page identify a card across repeated PDF analyses.
    var readingIdentity: String {
        let content: String
        switch self {
        case .title(let block): content = block.title
        case .text(let block): content = block.original
        case .figure(let block): content = block.caption
        case .table(let block): content = block.caption
        case .equation(let block): content = block.extractedEquation
        }
        return "\(pageNumber):\(typeName):\(content)"
    }

    var section: String? {
        switch self {
        case .title: nil
        case .text(let block): block.section
        case .figure(let block): block.section
        case .table(let block): block.section
        case .equation(let block): block.section
        }
    }
}
