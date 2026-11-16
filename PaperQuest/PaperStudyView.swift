//
//  PaperStudyView.swift
//  PaperQuest
//
//  Created by 임준혁 on 7/17/26.
//

import SwiftUI

struct PaperStudyView: View {
    let paperTitle: String
    let blocks: [PaperBlock]
    let pdfURL: URL
    @State private var showOriginalPDF = false

    @State private var currentIndex = 0
    @State private var showCompletionSheet = false
    @State private var isCompleted: Bool
    @State private var saveError: String?
    private let onProgressChange: (Int, Bool) throws -> Void

    init(
        paperTitle: String,
        blocks: [PaperBlock],
        initialIndex: Int = 0,
        initiallyCompleted: Bool = false,
        pdfURL: URL,
        onProgressChange: @escaping (Int, Bool) throws -> Void = { _, _ in }
    ) {
        self.paperTitle = paperTitle
        self.blocks = blocks
        self.pdfURL = pdfURL
        self.onProgressChange = onProgressChange
        _currentIndex = State(initialValue: min(max(0, initialIndex), max(0, blocks.count - 1)))
        _isCompleted = State(initialValue: initiallyCompleted)
    }

    private var currentBlock: PaperBlock? {
        guard blocks.indices.contains(currentIndex)
        else {
            return nil
        }

        return blocks[currentIndex]
    }

    var body: some View {
        Group {
            if let currentBlock {
                VStack(spacing: 10) {
                    progressSection

                    ScrollView {
                        PaperBlockView(
                            block: currentBlock,
                            pdfURL: pdfURL
                        )
                        .padding(.vertical, 4)
                    }
                    .id(currentIndex)
                    // Swipe sideways to move between cards; vertical drags still scroll.
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 30).onEnded { value in
                            let horizontal = value.translation.width
                            guard abs(horizontal) > 80,
                                  abs(horizontal) > abs(value.translation.height) * 2
                            else { return }
                            if horizontal < 0 {
                                goToNextBlock()
                            } else if currentIndex > 0 {
                                move(to: currentIndex - 1, completed: isCompleted)
                            }
                        }
                    )

                    navigationButtons
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else {
                ContentUnavailableView(
                    "학습 카드가 없습니다",
                    systemImage:
                        "rectangle.stack.badge.exclamationmark",
                    description:
                        Text(
                            "이 PDF에서 학습할 내용을 찾지 못했습니다."
                        )
                )
            }
        }
        .navigationTitle(paperTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showOriginalPDF = true
                } label: {
                    Label("원문 보기", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        .sheet(isPresented: $showOriginalPDF) {
            OriginalPDFView(url: pdfURL, pageNumber: currentBlock?.pageNumber ?? 1)
        }
        .sheet(
            isPresented: $showCompletionSheet
        ) {
            CompletionView(
                cardCount: blocks.count
            ) {
                // Rereading from the start keeps the paper marked as completed.
                move(to: 0, completed: true)
            }
            .presentationDetents([.large])
        }
        .alert("읽던 위치를 저장하지 못했습니다", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private var progressSection: some View {
        VStack(spacing: 8) {
            HStack {
                if let currentBlock {
                    Label(
                        currentBlock.typeName,
                        systemImage:
                            currentBlock.systemImage
                    )
                    .font(.subheadline)
                    .fontWeight(.semibold)
                }

                Spacer()

                Text(
                    "\(currentIndex + 1) / \(blocks.count)"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            ProgressView(
                value: Double(currentIndex + 1),
                total: Double(blocks.count)
            )
            .tint(.blue)
        }
    }

    private var navigationButtons: some View {
        HStack(spacing: 12) {
            Button {
                guard currentIndex > 0 else {
                    return
                }

                move(to: currentIndex - 1, completed: isCompleted)
            } label: {
                Label(
                    "이전",
                    systemImage: "chevron.left"
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .disabled(currentIndex == 0)

            Button {
                goToNextBlock()
            } label: {
                HStack {
                    Text(
                        currentIndex ==
                            blocks.count - 1
                        ? "완료"
                        : "다음"
                    )

                    Image(
                        systemName:
                            currentIndex ==
                                blocks.count - 1
                            ? "checkmark"
                            : "chevron.right"
                    )
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func goToNextBlock() {
        if currentIndex == blocks.count - 1 {
            if move(to: currentIndex, completed: true) {
                showCompletionSheet = true
            }
            return
        }

        move(to: currentIndex + 1, completed: isCompleted)
    }

    @discardableResult
    private func move(to index: Int, completed: Bool) -> Bool {
        do {
            try onProgressChange(index, completed)
            withAnimation {
                currentIndex = index
                isCompleted = completed
            }
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }
}

struct PaperBlockView: View {
    let block: PaperBlock
    let pdfURL: URL

    var body: some View {
        // Identity resets per-card state such as loaded translations when the card changes.
        switch block {
        case .title(let block):
            TitleBlockView(block: block, pdfURL: pdfURL)
                .id(PaperBlock.title(block).readingIdentity)

        case .text(let block):
            TextBlockView(block: block, pdfURL: pdfURL)
                .id(PaperBlock.text(block).readingIdentity)

        case .figure(let block):
            FigureBlockView(block: block, pdfURL: pdfURL)
                .id(PaperBlock.figure(block).readingIdentity)

        case .table(let block):
            TableBlockView(block: block, pdfURL: pdfURL)
                .id(PaperBlock.table(block).readingIdentity)

        case .equation(let block):
            EquationBlockView(block: block, pdfURL: pdfURL)
                .id(PaperBlock.equation(block).readingIdentity)
        }
    }
}
