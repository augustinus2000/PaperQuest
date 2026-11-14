import SwiftUI
import PDFKit

struct OriginalPDFView: View {
    let url: URL
    let pageNumber: Int
    @Environment(\.dismiss) private var dismiss
    @State private var document: PDFDocument?
    @State private var didLoad = false

    var body: some View {
        NavigationStack {
            Group {
                if let document {
                    PDFDocumentView(document: document, pageNumber: pageNumber)
                } else if didLoad {
                    ContentUnavailableView(
                        "원문을 열지 못했습니다",
                        systemImage: "doc.badge.exclamationmark",
                        description: Text("저장된 PDF 파일을 확인해 주세요.")
                    )
                } else {
                    ProgressView("원문을 여는 중")
                }
            }
            .navigationTitle("논문 원문")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기") { dismiss() }
                }
            }
            .task {
                guard !didLoad else { return }
                document = PDFDocument(url: url)
                didLoad = true
            }
        }
    }
}

private struct PDFDocumentView: UIViewRepresentable {
    let document: PDFDocument
    let pageNumber: Int

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.document = document
        if let page = document.page(at: min(max(0, pageNumber - 1), max(0, document.pageCount - 1))) {
            view.go(to: page)
        }
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        // The sheet opens at the requested page once. Keep the reader's
        // subsequent scroll and zoom position when SwiftUI updates the view.
    }
}
