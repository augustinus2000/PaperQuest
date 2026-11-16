//
//  ReflowView.swift
//  PaperQuest
//

import CoreImage
import CoreImage.CIFilterBuiltins
import OSLog
import PDFKit
import SwiftUI
import UIKit

/// Shows a paragraph at reading size by re-wrapping images of its original words.
/// Glyphs keep the paper's typography (italics, inline math) while the text fills the screen.
struct ReflowTextView: View {
    let pdfURL: URL
    let regions: [PDFRegion]
    let fontSize: CGFloat
    let accessibilityText: String
    @Environment(\.displayScale) private var displayScale
    @State private var words: [RenderedWord]?

    var body: some View {
        Group {
            if let words, !words.isEmpty {
                ReflowLayout(wordSpacing: fontSize * 0.3, lineSpacing: fontSize * 0.45) {
                    ForEach(words.indices, id: \.self) { index in
                        let word = words[index]
                        Image(uiImage: word.image)
                            .renderingMode(.template)
                            .resizable()
                            .frame(width: word.size.width, height: word.size.height)
                            .layoutValue(key: WordMetrics.self, value: WordMetrics(ascent: word.ascent, startsLine: word.startsLine))
                    }
                }
                .foregroundStyle(.primary)
            } else if words == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                // Nothing extractable; fall back to the original region.
                PDFRegionView(pdfURL: pdfURL, regions: regions, accessibilityText: accessibilityText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .task(id: "\(regions.hashValue)-\(fontSize)-\(displayScale)") {
            words = ReflowRenderer.words(for: regions, in: pdfURL, fontSize: fontSize, displayScale: displayScale)
        }
    }
}

struct RenderedWord {
    /// Ink as alpha, tinted by the view so it follows light/dark mode.
    let image: UIImage
    let size: CGSize
    /// Distance from the top of the image to the text baseline, in points.
    let ascent: CGFloat
    let startsLine: Bool
}

@MainActor
enum ReflowRenderer {
    private static let context = CIContext()

    static func words(for regions: [PDFRegion], in url: URL, fontSize: CGFloat, displayScale: CGFloat) -> [RenderedWord] {
        guard let document = PDFRegionRenderer.shared.document(for: url) else { return [] }
        let (paragraph, extractTime) = PerformanceLog.measure("Reflow extract") {
            ReflowExtractor.paragraph(for: regions, in: document)
        }
        // A typical letter box is about 1.15 × the font size.
        let zoom = fontSize * 1.15 / max(paragraph.letterHeight, 1)

        let (rendered, renderTime) = PerformanceLog.measure("Reflow render") {
            var sheets: [SheetKey: Sheet] = [:]
            return paragraph.words.compactMap { word -> RenderedWord? in
                let pieces = word.pieces.compactMap { piece -> (CGImage, CGSize, CGFloat, CGFloat)? in
                    let scale = zoom * piece.scale
                    let key = SheetKey(pageIndex: piece.pageIndex, scale: scale)
                    if sheets[key] == nil {
                        // One mask per page and scale; words are cropped from it.
                        let bounds = paragraph.words.flatMap(\.pieces)
                            .filter { $0.pageIndex == piece.pageIndex && $0.scale == piece.scale }
                            .map(\.rect)
                            .reduce(CGRect.null) { $0.union($1) }
                        sheets[key] = sheet(page: document.page(at: piece.pageIndex), rect: bounds, pixelScale: scale * displayScale)
                    }
                    guard let sheet = sheets[key], let image = sheet.crop(piece.rect) else { return nil }
                    let size = CGSize(width: piece.rect.width * scale, height: piece.rect.height * scale)
                    return (image, size, (piece.rect.maxY - piece.baseline) * scale, (piece.baseline - piece.rect.minY) * scale)
                }
                guard !pieces.isEmpty else { return nil }
                let ascent = pieces.map(\.2).max() ?? 0
                let descent = pieces.map(\.3).max() ?? 0
                let size = CGSize(width: pieces.reduce(0) { $0 + $1.1.width }, height: ascent + descent)
                let format = UIGraphicsImageRendererFormat()
                format.scale = displayScale
                format.opaque = false
                let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    var x: CGFloat = 0
                    for (cgImage, pieceSize, pieceAscent, _) in pieces {
                        UIImage(cgImage: cgImage).draw(in: CGRect(x: x, y: ascent - pieceAscent, width: pieceSize.width, height: pieceSize.height))
                        x += pieceSize.width
                    }
                }
                return RenderedWord(image: image, size: size, ascent: ascent, startsLine: word.startsLine)
            }
        }
        PerformanceLog.logger.info("""
            reflow: words=\(rendered.count) \
            extract=\(PerformanceLog.milliseconds(extractTime), privacy: .public) \
            render=\(PerformanceLog.milliseconds(renderTime), privacy: .public)
            """)
        return rendered
    }

    private struct SheetKey: Hashable {
        let pageIndex: Int
        let scale: CGFloat
    }

    /// A page area rendered once, with ink converted to alpha.
    private struct Sheet {
        let image: CGImage
        let rect: CGRect
        let pixelScale: CGFloat

        func crop(_ piece: CGRect) -> CGImage? {
            let pixels = CGRect(
                x: (piece.minX - rect.minX) * pixelScale,
                y: (rect.maxY - piece.maxY) * pixelScale,
                width: piece.width * pixelScale,
                height: piece.height * pixelScale
            ).integral
            return image.cropping(to: pixels)
        }
    }

    private static func sheet(page: PDFPage?, rect: CGRect, pixelScale: CGFloat) -> Sheet? {
        guard let page, !rect.isNull, rect.width > 0, rect.height > 0 else { return nil }
        page.displaysAnnotations = false
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let pixelSize = CGSize(width: rect.width * pixelScale, height: rect.height * pixelScale)
        let rendered = UIGraphicsImageRenderer(size: pixelSize, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: pixelSize))
            let cgContext = context.cgContext
            cgContext.translateBy(x: 0, y: pixelSize.height)
            cgContext.scaleBy(x: pixelScale, y: -pixelScale)
            cgContext.translateBy(x: -rect.minX, y: -rect.minY)
            page.draw(with: .mediaBox, to: cgContext)
        }
        // Dark ink → opaque, white paper → transparent, so the view can tint the text.
        guard let input = CIImage(image: rendered) else { return nil }
        let invert = CIFilter.colorInvert()
        invert.inputImage = input
        let mask = CIFilter.maskToAlpha()
        mask.inputImage = invert.outputImage
        guard let output = mask.outputImage,
              let image = context.createCGImage(output, from: input.extent)
        else {
            return nil
        }
        return Sheet(image: image, rect: rect, pixelScale: pixelScale)
    }
}

// MARK: - Layout

struct WordMetrics: LayoutValueKey {
    static let defaultValue = WordMetrics(ascent: 0, startsLine: false)
    let ascent: CGFloat
    let startsLine: Bool
}

/// Wraps words like text, aligning each row on a shared baseline.
struct ReflowLayout: Layout {
    let wordSpacing: CGFloat
    let lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        let rows = makeRows(width: width, subviews: subviews)
        return CGSize(width: width, height: rows.last.map { $0.top + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in makeRows(width: bounds.width, subviews: subviews) {
            for item in row.items {
                let metrics = subviews[item.index][WordMetrics.self]
                let size = subviews[item.index].sizeThatFits(.unspecified)
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.top + row.ascent - metrics.ascent),
                    proposal: ProposedViewSize(size)
                )
            }
        }
    }

    private struct Row {
        var items: [(index: Int, x: CGFloat)] = []
        var top: CGFloat = 0
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var height: CGFloat { ascent + descent }
    }

    private func makeRows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0
        func finish() {
            current.top = rows.last.map { $0.top + $0.height + lineSpacing } ?? 0
            rows.append(current)
            current = Row()
            x = 0
        }
        for index in subviews.indices {
            let metrics = subviews[index][WordMetrics.self]
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.items.isEmpty, metrics.startsLine || x + size.width > width {
                finish()
            }
            current.items.append((index, x))
            current.ascent = max(current.ascent, metrics.ascent)
            current.descent = max(current.descent, size.height - metrics.ascent)
            x += size.width + wordSpacing
        }
        if !current.items.isEmpty {
            finish()
        }
        return rows
    }
}
