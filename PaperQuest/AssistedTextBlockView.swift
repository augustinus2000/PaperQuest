import SwiftUI
import Translation

/// On-device translation and AI explanation for one card, cached next to the PDF.
@available(iOS 18.0, *)
struct ReadingAssistancePanel: View {
    let kind: AssistanceSourceKind
    /// `nil` hides translation, e.g. when an equation has no surrounding prose.
    let translationSource: String?
    let explanationSource: String
    /// Background for the explanation model, e.g. the preceding paragraph.
    var explanationContext: String? = nil
    var allowsExplanation = true
    let identity: String
    let pdfURL: URL

    @State private var assistance = ReadingAssistance()
    @State private var configuration: TranslationSession.Configuration?
    @State private var isTranslating = false
    @State private var isExplaining = false
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    @State private var explanationRequest = false

    private var cacheURL: URL {
        ReadingAssistanceStore.fileURL(pdfURL: pdfURL, identity: identity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let translation = assistance.translation {
                DisclosureGroup("\(kind.translationTitle) · 기기에 저장됨") {
                    Text(translation)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
                .assistanceResultStyle(tint: .green)
            } else if translationSource != nil {
                Button {
                    errorMessage = nil
                    isTranslating = true
                    if configuration == nil {
                        configuration = .init(
                            source: Locale.Language(identifier: "en"),
                            target: Locale.Language(identifier: "ko")
                        )
                    } else {
                        configuration?.invalidate()
                    }
                } label: {
                    Label("\(kind.translationTitle) 보기", systemImage: "character.book.closed")
                }
                .disabled(!hasLoaded || isTranslating || isExplaining)
            }

            if !allowsExplanation {
                EmptyView()
            } else if let explanation = assistance.explanation {
                DisclosureGroup("AI 해설 · 기기에 저장됨") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Self.rendered(explanation)).textSelection(.enabled)
                        Text(kind.explanationNote)
                            .font(.caption).foregroundStyle(.secondary)
                        // The on-device model varies between runs, so allow another attempt.
                        Button {
                            errorMessage = nil
                            explanationRequest = true
                        } label: {
                            Label("해설 다시 만들기", systemImage: "arrow.clockwise")
                                .font(.subheadline)
                        }
                        .disabled(isTranslating || isExplaining || explanationRequest)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                }
                .assistanceResultStyle(tint: .orange)
            } else {
                Button {
                    errorMessage = nil
                    explanationRequest = true
                } label: {
                    Label(kind.explanationButtonTitle, systemImage: "sparkles")
                }
                .disabled(!hasLoaded || isTranslating || isExplaining || explanationRequest)
            }

            if isTranslating || isExplaining {
                ProgressView(isTranslating ? "기기에서 번역하는 중…" : "기기에서 해설을 만드는 중…")
            }
            Text("영어 → 한국어 번역 · 처음에는 언어 모델 다운로드가 필요할 수 있어요. AI 해설은 Apple Intelligence 지원 기기에서 제공됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !hasLoaded {
                    Button("저장된 결과 다시 불러오기") { loadSavedResults() }
                }
            }
        }
        .task { loadSavedResults() }
        .translationTask(configuration) { session in
            guard isTranslating, let translationSource else { return }
            defer { isTranslating = false }
            do {
                let response = try await session.translate(translationSource)
                try Task.checkCancellation()
                var updated = assistance
                updated.translation = response.targetText
                try ReadingAssistanceStore.save(updated, to: cacheURL)
                assistance = updated
            } catch {
                // Report every failure, including dismissing the system language sheet.
                // If the card already disappeared, its discarded state ignores this.
                errorMessage = error is CancellationError
                    ? "번역이 취소되었습니다. 다시 시도하려면 번역 버튼을 눌러 주세요."
                    : "번역 또는 저장을 완료하지 못했습니다. 언어 모델 준비 상태를 확인하고 다시 시도해 주세요.\n" + error.localizedDescription
            }
        }
        .task(id: explanationRequest) {
            guard explanationRequest else { return }
            isExplaining = true
            defer {
                isExplaining = false
                explanationRequest = false
            }
            if #available(iOS 26.0, *) {
                if let reason = OnDeviceExplanation.unavailableReason {
                    errorMessage = reason
                    return
                }
                do {
                    let explanation = try await OnDeviceExplanation.explain(
                        explanationSource, kind: kind, context: explanationContext
                    )
                    try Task.checkCancellation()
                    var updated = assistance
                    updated.explanation = explanation
                    updated.explanationVersion = OnDeviceExplanation.promptVersion
                    try ReadingAssistanceStore.save(updated, to: cacheURL)
                    assistance = updated
                } catch {
                    if !Task.isCancelled {
                        errorMessage = "해설 생성 또는 저장을 완료하지 못했습니다. 다시 시도해 주세요.\n" + error.localizedDescription
                    }
                }
            } else {
                errorMessage = "AI 해설은 iOS 26 이상과 Apple Intelligence 지원 기기가 필요합니다."
            }
        }
    }

    /// The model sometimes answers with Markdown such as **bold**; show it styled, not as symbols.
    private static func rendered(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private func loadSavedResults() {
        guard !hasLoaded else { return }
        do {
            assistance = try ReadingAssistanceStore.load(from: cacheURL)
            hasLoaded = true
            errorMessage = nil
        } catch {
            errorMessage = "저장된 번역·해설을 불러오지 못했습니다.\n" + error.localizedDescription
        }
    }
}

private extension View {
    /// Matches `StudySection` so saved results sit inside the same inset card.
    func assistanceResultStyle(tint: Color) -> some View {
        self
            .tint(tint)
            .padding()
            .background(tint.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}
