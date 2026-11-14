//
//  PDFImportService.swift
//  PaperQuest
//
//  Created by 임준혁 on 7/17/26.
//

import PDFKit

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

        guard hasText(document) else {
            throw PDFImportError.emptyText
        }

        return ImportedPaper(
            fileName:
                url.deletingPathExtension()
                    .lastPathComponent,
            document: document,
            pageCount: document.pageCount
        )
    }

    /// Stops at the first page with text; the analyzer reads the lines itself,
    /// so extracting every page's string here would only repeat that work.
    private static func hasText(
        _ document: PDFDocument
    ) -> Bool {
        (0..<document.pageCount).contains { pageIndex in
            let text = document.page(at: pageIndex)?.string ?? ""
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
