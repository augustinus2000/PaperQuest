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

            StudySection(title: "제목", systemImage: "doc.richtext", content: block.title, tint: .accentColor)
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
    /// Large re-wrapped text by default; the original layout is one tap away.
    @AppStorage("showsOriginalLayout") private var showsOriginalLayout = false
    @AppStorage("readingFontSize") private var fontSize = 19.0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardHeader(pageNumber: block.pageNumber, section: block.section)

            HStack {
                Picker("보기 방식", selection: $showsOriginalLayout) {
                    Text("크게 읽기").tag(false)
                    Text("원본").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)

                Spacer()

                if !showsOriginalLayout {
                    Button {
                        fontSize = max(15, fontSize - 2)
                    } label: {
                        Image(systemName: "textformat.size.smaller")
                    }
                    .accessibilityLabel("글자 작게")
                    .disabled(fontSize <= 15)
                    Button {
                        fontSize = min(29, fontSize + 2)
                    } label: {
                        Image(systemName: "textformat.size.larger")
                    }
                    .accessibilityLabel("글자 크게")
                    .disabled(fontSize >= 29)
                }
            }
            .buttonStyle(.bordered)

            if showsOriginalLayout {
                PDFRegionView(pdfURL: pdfURL, regions: block.regions, accessibilityText: block.original)
            } else {
                ReflowTextView(
                    pdfURL: pdfURL, regions: block.regions,
                    fontSize: fontSize, accessibilityText: block.original
                )
            }

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
/// Tapping opens every region of the card in a zoomable sheet.
struct PDFRegionView: View {
    let pdfURL: URL
    let regions: [PDFRegion]
    let accessibilityText: String
    var isZoomable = true
    @State private var isZoomed = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(regions, id: \.self) { region in
                PDFRegionImage(pdfURL: pdfURL, region: region)
            }
        }
        .padding(6)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2))
        }
        // The hint sits just above the box so it never covers the paper's text.
        .overlay(alignment: .topTrailing) {
            if isZoomable {
                Label("탭하여 확대", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    // Lift it into the gap above the box (cards space their parts 16pt apart).
                    .offset(y: -15)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isZoomable {
                isZoomed = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isZoomable ? .isButton : [])
        .accessibilityHint(isZoomable ? "확대해서 봅니다" : "")
        .fullScreenCover(isPresented: $isZoomed) {
            ZoomedRegionSheet(pdfURL: pdfURL, regions: regions)
        }
    }
}

private struct ZoomedRegionSheet: View {
    let pdfURL: URL
    let regions: [PDFRegion]
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    ZoomableImage(image: image)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ProgressView()
                }
            }
            .background(Color.white)
            .navigationTitle("두 손가락 또는 두 번 탭으로 확대")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        .task {
            // Higher resolution than the card so text stays sharp when zoomed in.
            image = PDFRegionRenderer.shared.stitchedImage(for: regions, in: pdfURL, scale: 6)
        }
    }
}

/// Fits the image to the screen width, scrolls vertically when it is taller,
/// and zooms with a pinch or a double tap.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = CenteringScrollView()
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.backgroundColor = .white
        scrollView.delegate = context.coordinator

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)
        let aspect = image.size.height / max(image.size.width, 1)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: aspect)
        ])
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.toggleZoom(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
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

        @objc func toggleZoom(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView, let imageView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                // Zoom 2.5x around the tapped point.
                let point = gesture.location(in: imageView)
                let size = CGSize(
                    width: scrollView.bounds.width / 2.5,
                    height: scrollView.bounds.height / 2.5
                )
                let rect = CGRect(
                    x: point.x - size.width / 2, y: point.y - size.height / 2,
                    width: size.width, height: size.height
                )
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}

/// Keeps content smaller than the screen centered instead of pinned to the top-left.
private final class CenteringScrollView: UIScrollView {
    override func layoutSubviews() {
        super.layoutSubviews()
        // Safe-area insets are added on top of contentInset automatically.
        let visibleHeight = bounds.height - safeAreaInsets.top - safeAreaInsets.bottom
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, ((visibleHeight - contentSize.height) / 2).rounded(.down))
        let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if contentInset != inset {
            contentInset = inset
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

    /// All regions of a card stacked top to bottom, e.g. a paragraph spanning two columns.
    func stitchedImage(for regions: [PDFRegion], in url: URL, scale: CGFloat) -> UIImage? {
        let images = regions.compactMap { image(for: $0, in: url, scale: scale) }
        guard images.count > 1 else { return images.first }
        let width = images.map(\.size.width).max() ?? 0
        let height = images.reduce(0) { $0 + $1.size.height }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            var y: CGFloat = 0
            for image in images {
                image.draw(at: CGPoint(x: 0, y: y))
                y += image.size.height
            }
        }
    }

    /// The open document for `url`, reused across cards of the same paper.
    func document(for url: URL) -> PDFDocument? {
        if openDocument?.url != url {
            openDocument = PDFDocument(url: url).map { (url, $0) }
        }
        return openDocument?.document
    }

    func image(for region: PDFRegion, in url: URL, scale: CGFloat = 4) -> UIImage? {
        let key = "\(url.lastPathComponent)#\(region.pageIndex)#\(region.rect.debugDescription)#\(scale)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let page = document(for: url)?.page(at: region.pageIndex) else { return nil }
        // Link borders (boxes around citations) are not part of the typeset text.
        page.displaysAnnotations = false
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
