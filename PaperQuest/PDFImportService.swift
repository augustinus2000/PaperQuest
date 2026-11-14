//
//  PDFImportService.swift
//  PaperQuest
//
//  Created by 임준혁 on 7/17/26.
//

import PDFKit
import UIKit

nonisolated enum PDFImportError: LocalizedError {
    case invalidDocument
    case emptyText

    var errorDescription: String? {
        switch self {
        case .invalidDocument:
            return "올바른 PDF 파일이 아닙니다."

        case .emptyText:
            return """
            이 PDF에서 텍스트를 찾지 못했습니다.
            스캔 이미지로 만들어진 PDF일 수 있습니다.
            """
        }
    }
}

nonisolated enum PDFImportService {
    static func importPaper(
        from url: URL
    ) throws -> ImportedPaper {
        let hasAccess =
            url.startAccessingSecurityScopedResource()

        defer {
            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let document = PDFDocument(url: url) else {
            throw PDFImportError.invalidDocument
        }

        let pages = extractPages(from: document)

        let completeText = pages
            .map(\.text)
            .joined(separator: "\n\n")
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !completeText.isEmpty else {
            throw PDFImportError.emptyText
        }

        return ImportedPaper(
            fileName:
                url.deletingPathExtension()
                    .lastPathComponent,
            document: document,
            pages: pages,
            completeText: completeText
        )
    }

    private static func extractPages(
        from document: PDFDocument
    ) -> [PDFPageContent] {
        var pages: [PDFPageContent] = []

        for pageIndex in 0..<document.pageCount {
            guard let page =
                document.page(at: pageIndex)
            else {
                continue
            }

            let text = page.string?
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                ) ?? ""

            pages.append(
                PDFPageContent(
                    pageIndex: pageIndex,
                    text: text
                )
            )
        }

        return pages
    }
}
