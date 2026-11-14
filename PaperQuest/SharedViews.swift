//
//  SharedViews.swift
//  PaperQuest
//
//  Created by 임준혁 on 7/17/26.
//

import OSLog
import PDFKit
import SwiftUI
import UIKit

// MARK: - Cards

struct TitleBlockView: View {
    let block: TitleBlock
    let pdfURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardHeader(pageNumber: block.pageNumber, section: "제목 · 저자")

            PDFRegionView(
                pdfURL: pdfURL, regions: [block.region], accessibilityText: block.title, isZoomable: true
            )

            StudySection(title: "제목", systemImage: "doc.richtext", content: block.title, tint: .blue)
                .textSelection(.enabled)

            // Explaining a title adds little; translation is enough here.
            ReadingAssistancePanel(
                kind: .paragraph,
                translationSource: block.title,
                explanationSource: block.title,
                allowsExplanation: false,
                identity: PaperBlock.title(block).readingIdentity,
                pdfURL: pdfURL
            )
        }
    }
}

struct TextBlockView: View {
    let block: TextBlock
    let pdfURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardHeader(pageNumber: block.pageNumber, section: block.section)

            PDFRegionView(pdfURL: pdfURL, regions: block.regions, accessibilityText: block.original)

            ExtractedTextDisclosure(text: block.original)

            ReadingAssistancePanel(
                kind: .paragraph,
                translationSource: block.original,
                explanationSource: block.original,
                explanationContext: explanationContext,
                identity: PaperBlock.text(block).readingIdentity,
                pdfURL: pdfURL
            )
        }
    }

    private var explanationContext: String? {
        let parts = [
            block.section.map { "Section: \($0)" },
            block.context.map { "Preceding paragraph: \($0)" }
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}

struct FigureBlockView: View {
    let block: FigureBlock
    let pdfURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardHeader(pageNumber: block.pageNumber, section: block.section)

            PDFRegionView(
                pdfURL: pdfURL, regions: [block.region], accessibilityText: block.caption, isZoomable: true
            )

            StudySection(
                title: block.isAlgorithm ? "Algorithm" : "Figure Caption",
                systemImage: block.isAlgorithm ? "list.number" : "photo",
                content: block.caption,
                tint: .purple
            )
            .textSelection(.enabled)

            ReadingAssistancePanel(
                kind: block.isAlgorithm ? .algorithm : .figureCaption,
                translationSource: block.caption,
                explanationSource: [block.caption, block.content].compactMap { $0 }.joined(separator: "\n"),
                explanationContext: block.context.map { "Paragraph that mentions it: \($0)" },
                identity: PaperBlock.figure(block).readingIdentity,
                pdfURL: pdfURL
            )
        }
    }
}

struct TableBlockView: View {
    let block: TableBlock
    let pdfURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardHeader(pageNumber: block.pageNumber, section: block.section)

            StudySection(
                title: "Table Caption",
                systemImage: "tablecells",
                content: block.caption,
                tint: .purple
            )
            .textSelection(.enabled)

            PDFRegionView(
                pdfURL: pdfURL, regions: [block.region], accessibilityText: block.caption, isZoomable: true
            )

            ReadingAssistancePanel(
                kind: .tableCaption,
                translationSource: block.caption,
                explanationSource: block.caption,
                explanationContext: block.context.map { "Paragraph that mentions it: \($0)" },
                identity: PaperBlock.table(block).readingIdentity,
                pdfURL: pdfURL
            )
        }
    }
}

struct EquationBlockView: View {
    let block: EquationBlock
    let pdfURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardHeader(pageNumber: block.pageNumber, section: block.section)

            PDFRegionView(
                pdfURL: pdfURL,
                regions: block.regions,
                accessibilityText: [block.leadIn, block.extractedEquation, block.followUp]
                    .compactMap { $0 }.joined(separator: " ")
            )

            ReadingAssistancePanel(
                kind: .equation,
                translationSource: block.prose,
                explanationSource: explanationSource,
                explanationContext: block.surroundingText.isEmpty ? nil : block.surroundingText,
                identity: PaperBlock.equation(block).readingIdentity,
                pdfURL: pdfURL
            )
        }
    }

    private var explanationSource: String {
        [
            block.leadIn,
            "Equation: \(block.extractedEquation)",
            block.followUp
        ].compactMap { $0 }.joined(separator: "\n")
    }
}

// MARK: - Card Parts

private struct CardHeader: View {
    let pageNumber: Int
    let section: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let section {
                Text(section)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            pageLabel(pageNumber)
        }
    }
}

private struct ExtractedTextDisclosure: View {
    let text: String

    var body: some View {
        DisclosureGroup("추출된 텍스트 보기") {
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
        }
        .font(.subheadline)
    }
}

/// Shows PDF regions exactly as typeset, so math, italics and figures stay intact.
struct PDFRegionView: View {
    let pdfURL: URL
    let regions: [PDFRegion]
    let accessibilityText: String
    /// Figures and tables are often too small at card width, so they open in a zoomable sheet.
    var isZoomable = false
    @State private var zoomedRegion: PDFRegion?

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            VStack(spacing: 0) {
                ForEach(regions, id: \.self) { region in
                    PDFRegionImage(pdfURL: pdfURL, region: region)
                }
            }
            .padding(10)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.secondary.opacity(0.2))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isZoomable {
                    zoomedRegion = regions.first
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(isZoomable ? .isButton : [])
            .accessibilityHint(isZoomable ? "확대해서 봅니다" : "")

            if isZoomable {
                Label("탭해서 크게 보기", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(item: $zoomedRegion) { region in
            ZoomedRegionSheet(pdfURL: pdfURL, region: region)
        }
    }
}

private struct ZoomedRegionSheet: View {
    let pdfURL: URL
    let region: PDFRegion
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    ZoomableImage(image: image)
                } else {
                    ProgressView()
                }
            }
            .background(Color.white)
            .navigationTitle("두 손가락으로 확대")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        .task {
            // Higher resolution than the card so text stays sharp when zoomed in.
            image = PDFRegionRenderer.shared.image(for: region, in: pdfURL, scale: 6)
        }
    }
}

private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.backgroundColor = .white
        scrollView.delegate = context.coordinator

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
        context.coordinator.imageView = imageView
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }
    }
}

private struct PDFRegionImage: View {
    let pdfURL: URL
    let region: PDFRegion
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.white
                    .aspectRatio(region.rect.width / max(region.rect.height, 1), contentMode: .fit)
            }
        }
        .task(id: region) {
            image = PDFRegionRenderer.shared.image(for: region, in: pdfURL)
        }
    }
}

/// Renders PDF page regions on demand and caches them, so cards never keep full-page bitmaps.
@MainActor
final class PDFRegionRenderer {
    static let shared = PDFRegionRenderer()

    private var openDocument: (url: URL, document: PDFDocument)?
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.totalCostLimit = 80 * 1_024 * 1_024
    }

    func image(for region: PDFRegion, in url: URL, scale: CGFloat = 4) -> UIImage? {
        let key = "\(url.lastPathComponent)#\(region.pageIndex)#\(region.rect.debugDescription)#\(scale)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        if openDocument?.url != url {
            openDocument = PDFDocument(url: url).map { (url, $0) }
        }
        guard let page = openDocument?.document.page(at: region.pageIndex) else { return nil }
        let box = page.bounds(for: .mediaBox)
        // Whole points avoid an unpainted (dark) pixel column at fractional edges.
        let rect = region.rect.intersection(box).integral
        guard !rect.isNull, rect.width > 1, rect.height > 1 else { return nil }

        // Column-width regions are shown wider than their PDF size, so render above screen scale.
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let (image, renderTime) = PerformanceLog.measure("Region render") {
            UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: rect.size))
            let cgContext = context.cgContext
            // PDF space is y-up: flip, then move the region's origin to (0, 0).
            cgContext.translateBy(x: 0, y: rect.height)
            cgContext.scaleBy(x: 1, y: -1)
            cgContext.translateBy(x: box.minX - rect.minX, y: box.minY - rect.minY)
            page.draw(with: .mediaBox, to: cgContext)
            }
        }
        PerformanceLog.logger.info("""
            render region: page=\(region.pageIndex + 1) \
            size=\(Int(rect.width))x\(Int(rect.height))pt scale=\(Int(scale)) \
            time=\(PerformanceLog.milliseconds(renderTime), privacy: .public)
            """)
        let cost = Int(rect.width * rect.height * scale * scale * 4)
        cache.setObject(image, forKey: key, cost: cost)
        return image
    }
}

// MARK: - Shared Components

struct StudySection: View {
    let title: String
    let systemImage: String
    let content: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                title,
                systemImage: systemImage
            )
            .font(.headline)
            .foregroundStyle(tint)

            Text(content)
                .font(.body)
                .lineSpacing(5)
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading
                )
        }
        .padding()
        .background(tint.opacity(0.08))
        .clipShape(
            RoundedRectangle(cornerRadius: 18)
        )
    }
}

func pageLabel(
    _ pageNumber: Int
) -> some View {
    Label(
        "PDF \(pageNumber)페이지",
        systemImage: "doc"
    )
    .font(.caption)
    .foregroundStyle(.secondary)
}
