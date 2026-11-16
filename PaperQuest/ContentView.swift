import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var library = PaperLibrary()
    @State private var showPDFImporter = false
    @State private var selectedPaper: SavedPaper?
    @State private var errorTitle = ""
    @State private var errorMessage: String?
    @State private var isImporting = false
    @State private var paperPendingDeletion: SavedPaper?
    @State private var paperBeingRenamed: SavedPaper?
    @State private var newTitle = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let loadError = library.loadError {
                        ContentUnavailableView(
                            "서재를 열지 못했어요",
                            systemImage: "exclamationmark.triangle",
                            description: Text("앱을 다시 실행해 주세요.\n\(loadError)")
                        )
                    } else if library.papers.isEmpty {
                        EmptyLibraryView {
                            showPDFImporter = true
                        }
                        .disabled(isImporting)
                    } else {
                        if let paper = library.paperToResume {
                            ResumeCard(paper: paper, pdfURL: library.pdfURL(for: paper.id)) {
                                selectedPaper = paper
                            }
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("모든 논문")
                                    .font(.title3.weight(.semibold))
                                Text("\(library.papers.count)")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }

                            ForEach(library.recentPapers) { paper in
                                Button {
                                    selectedPaper = paper
                                } label: {
                                    PaperRow(
                                        paper: paper,
                                        pdfURL: library.pdfURL(for: paper.id),
                                        onRename: { startRenaming(paper) },
                                        onDelete: { paperPendingDeletion = paper }
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(isImporting)
                                .contextMenu {
                                    Button {
                                        startRenaming(paper)
                                    } label: {
                                        Label("이름 변경", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        paperPendingDeletion = paper
                                    } label: {
                                        Label("삭제", systemImage: "trash")
                                    }
                                }
                            }
                        }

                        Label("논문과 번역·해설은 이 iPhone에만 저장돼요", systemImage: "lock.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("서재")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showPDFImporter = true
                    } label: {
                        Label("논문 추가", systemImage: "plus")
                    }
                    .disabled(isImporting || library.loadError != nil)
                }
            }
            .overlay(alignment: .bottom) {
                if isImporting {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("논문을 준비하는 중…")
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .glassEffect()
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: isImporting)
            .fileImporter(isPresented: $showPDFImporter, allowedContentTypes: [.pdf]) { result in
                switch result {
                case .success(let url):
                    isImporting = true
                    Task {
                        defer { isImporting = false }
                        do {
                            selectedPaper = try await library.importPaper(from: url)
                        } catch {
                            showError("PDF를 저장하지 못했습니다", error)
                        }
                    }
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError {
                        showError("PDF를 저장하지 못했습니다", error)
                    }
                }
            }
            .navigationDestination(item: $selectedPaper) { paper in
                SavedPaperReader(paper: paper, library: library)
            }
            .confirmationDialog(
                "이 논문을 삭제할까요?",
                isPresented: Binding(
                    get: { paperPendingDeletion != nil },
                    set: { if !$0 { paperPendingDeletion = nil } }
                ),
                titleVisibility: .visible,
                presenting: paperPendingDeletion
            ) { paper in
                Button("삭제", role: .destructive) {
                    do {
                        try library.deletePaper(paper.id)
                    } catch {
                        showError("논문을 삭제하지 못했습니다", error)
                    }
                }
                Button("취소", role: .cancel) {}
            } message: { paper in
                Text("‘\(paper.title)’의 PDF, 읽던 위치, 번역·해설이 기기에서 함께 삭제됩니다.")
            }
            .alert(
                "이름 변경",
                isPresented: Binding(
                    get: { paperBeingRenamed != nil },
                    set: { if !$0 { paperBeingRenamed = nil } }
                ),
                presenting: paperBeingRenamed
            ) { paper in
                TextField("논문 이름", text: $newTitle)
                Button("저장") {
                    do {
                        try library.renamePaper(paper.id, to: newTitle)
                    } catch {
                        showError("이름을 바꾸지 못했습니다", error)
                    }
                }
                .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("취소", role: .cancel) {}
            } message: { _ in
                Text("서재에 표시할 이름을 입력하세요.")
            }
            .alert(errorTitle, isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func startRenaming(_ paper: SavedPaper) {
        newTitle = paper.title
        paperBeingRenamed = paper
    }

    private func showError(_ title: String, _ error: Error) {
        errorTitle = title
        errorMessage = error.localizedDescription
    }
}

// MARK: - Library Components

/// The paper the reader was last in the middle of, shown first.
private struct ResumeCard: View {
    let paper: SavedPaper
    let pdfURL: URL
    let onResume: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                PaperCover(pdfURL: pdfURL, width: 86)

                VStack(alignment: .leading, spacing: 6) {
                    Text("이어 읽기")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tint)
                    Text(paper.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(3)
                    Text("카드 \(paper.currentIndex + 1) / \(paper.cardCount)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            ProgressView(value: paper.progress)
                .tint(.accentColor)

            Button(action: onResume) {
                Label("이어서 읽기", systemImage: "book.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.18), Color(.secondarySystemGroupedBackground)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }
}

private struct PaperRow: View {
    let paper: SavedPaper
    let pdfURL: URL
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            PaperCover(pdfURL: pdfURL, width: 52)

            VStack(alignment: .leading, spacing: 6) {
                Text(paper.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                status
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button(action: onRename) {
                    Label("이름 변경", systemImage: "pencil")
                }
                Button(role: .destructive, action: onDelete) {
                    Label("삭제", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("논문 메뉴")
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var detail: String {
        // The UI is Korean, so keep dates Korean regardless of the device language.
        let style = Date.RelativeFormatStyle(presentation: .named).locale(Locale(identifier: "ko_KR"))
        if let opened = paper.lastOpenedAt {
            return "\(paper.pageCount)쪽 · \(opened.formatted(style)) 읽음"
        }
        return "\(paper.pageCount)쪽 · \(paper.addedAt.formatted(style)) 추가"
    }

    @ViewBuilder
    private var status: some View {
        if paper.isCompleted {
            Label("완독", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        } else if paper.cardCount > 0 {
            HStack(spacing: 8) {
                ProgressView(value: paper.progress)
                    .tint(.accentColor)
                Text(paper.progress, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } else {
            Text("새 논문")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
        }
    }
}

/// First page of the PDF as a small book-like cover.
private struct PaperCover: View {
    let pdfURL: URL
    let width: CGFloat
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.white
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "doc.text")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: width, height: width * 1.3, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        .accessibilityHidden(true)
        .task(id: pdfURL) {
            image = await PaperCoverCache.shared.cover(for: pdfURL)
        }
    }
}

/// Renders first-page thumbnails off the main actor and keeps them in memory.
@MainActor
private final class PaperCoverCache {
    static let shared = PaperCoverCache()
    private let cache = NSCache<NSURL, UIImage>()

    func cover(for url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }
        let image = await Self.render(url)
        if let image {
            cache.setObject(image, forKey: url as NSURL)
        }
        return image
    }

    @concurrent
    private nonisolated static func render(_ url: URL) async -> UIImage? {
        PDFDocument(url: url)?.page(at: 0)?.thumbnail(of: CGSize(width: 240, height: 320), for: .mediaBox)
    }
}

private struct EmptyLibraryView: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
                .padding(28)
                .background(Circle().fill(Color.accentColor.opacity(0.12)))

            VStack(spacing: 8) {
                Text("첫 논문을 담아 보세요")
                    .font(.title2.weight(.bold))
                Text("PDF를 추가하면 문단·그림·수식 단위의 카드로 나눠\n이동 중에도 한 장씩 가볍게 읽을 수 있어요.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(action: onAdd) {
                Label("논문 PDF 추가", systemImage: "plus")
                    .font(.headline)
                    .frame(minWidth: 200)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)

            Label("번역과 AI 해설은 모두 iPhone 안에서 처리돼요", systemImage: "lock.fill")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 72)
    }
}

private struct SavedPaperReader: View {
    let paper: SavedPaper
    let library: PaperLibrary
    @State private var blocks: [PaperBlock]?
    @State private var restoredPaper: SavedPaper?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let blocks {
                PaperStudyView(
                    paperTitle: paper.title,
                    blocks: blocks,
                    initialIndex: restoredPaper?.currentIndex ?? 0,
                    initiallyCompleted: restoredPaper?.isCompleted ?? false,
                    pdfURL: library.pdfURL(for: paper.id)
                ) { index, completed in
                    try library.saveProgress(
                        for: paper.id,
                        index: index,
                        cardCount: blocks.count,
                        completed: completed
                    )
                }
            } else if let errorMessage {
                ContentUnavailableView(
                    "논문을 열지 못했습니다",
                    systemImage: "doc.badge.exclamationmark",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("읽던 논문을 준비하고 있습니다")
            }
        }
        .task {
            guard blocks == nil, errorMessage == nil else { return }
            do {
                let result = try await library.openPaper(paper)
                restoredPaper = library.papers.first { $0.id == paper.id }
                blocks = result
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    ContentView()
}
