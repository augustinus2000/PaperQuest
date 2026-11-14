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
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("이동하는 동안, 한 문단씩")
                            .font(.title2.bold())
                        Text("읽던 논문을 열고 이어 읽어보세요. PDF와 읽던 위치는 기기에 저장됩니다.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)

                    Button {
                        showPDFImporter = true
                    } label: {
                        Label("논문 PDF 추가", systemImage: "plus.circle.fill")
                    }
                    .disabled(isImporting || library.loadError != nil)

                    if isImporting {
                        ProgressView("논문을 저장하고 있습니다")
                    }
                }

                Section("내 서재") {
                    if let loadError = library.loadError {
                        Text("서재를 열지 못했습니다. 앱을 다시 실행해 주세요.\n\(loadError)")
                            .foregroundStyle(.secondary)
                    } else if library.papers.isEmpty {
                        ContentUnavailableView(
                            "첫 논문을 추가해 보세요",
                            systemImage: "books.vertical",
                            description: Text("PDF를 추가하면 다음에도 이곳에서 이어 읽을 수 있어요.")
                        )
                    } else {
                        ForEach(library.papers) { paper in
                            Button {
                                selectedPaper = paper
                            } label: {
                                LibraryPaperRow(paper: paper)
                            }
                            .buttonStyle(.plain)
                            .disabled(isImporting)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    paperPendingDeletion = paper
                                } label: {
                                    Label("삭제", systemImage: "trash")
                                }
                                Button {
                                    startRenaming(paper)
                                } label: {
                                    Label("이름 변경", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
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
                }
            }
            .navigationTitle("PaperQuest")
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
                Text("내 서재에 표시할 이름을 입력하세요.")
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

private struct LibraryPaperRow: View {
    let paper: SavedPaper

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(paper.title)
                .font(.headline)
                .lineLimit(2)
            Text("\(paper.pageCount)페이지 · 기기에 저장됨")
                .font(.caption)
                .foregroundStyle(.secondary)
            if paper.cardCount > 0 {
                Text(paper.isCompleted
                     ? "추출된 카드 읽기 완료 · 다시 보기"
                     : "\(paper.currentIndex + 1) / \(paper.cardCount) 카드 · 이어 읽기")
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
            } else {
                Text("읽기 시작")
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
