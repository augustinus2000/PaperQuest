//
//  CompletionView.swift
//  PaperQuest
//
//  Created by 임준혁 on 7/18/26.
//

import SwiftUI

struct CompletionView: View {
    let cardCount: Int
    let onContinue: () -> Void

    @Environment(\.dismiss)
    private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(
                        Color.blue.opacity(0.12)
                    )
                    .frame(
                        width: 110,
                        height: 110
                    )

                Image(
                    systemName:
                        "checkmark.circle.fill"
                )
                .font(.system(size: 68))
                .foregroundStyle(.blue)
            }

            VStack(spacing: 10) {
                Text("오늘의 학습 완료!")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                Text(
                    "\(cardCount)개의 카드를 모두 읽었어요."
                )
                .font(.title3)
                .foregroundStyle(.secondary)

                Text("+\(cardCount * 10) EXP")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 14) {
                Label(
                    "논문 블록 \(cardCount)개 학습",
                    systemImage: "doc.text"
                )

                Label(
                    "오늘의 목표 달성",
                    systemImage: "flame.fill"
                )
            }
            .font(.headline)
            .padding(20)
            .frame(
                maxWidth: .infinity,
                alignment: .leading
            )
            .background(
                Color(.secondarySystemBackground)
            )
            .clipShape(
                RoundedRectangle(cornerRadius: 18)
            )

            Spacer()

            Button {
                onContinue()
                dismiss()
            } label: {
                Text("계속하기")
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
    }
}

