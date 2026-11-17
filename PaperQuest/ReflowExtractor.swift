//
//  ReflowExtractor.swift
//  PaperQuest
//

import CoreGraphics
import Foundation
import PDFKit

/// A word cut from the PDF, to be redrawn at reading size and re-wrapped.
/// Words stay images of the original glyphs, so italics and inline math survive.
nonisolated struct ReflowWord: Sendable, Hashable {
    /// One piece for a normal word; two when a hyphenated line break is joined.
    struct Piece: Sendable, Hashable {
        let pageIndex: Int
        /// Glyph bounds in PDF page coordinates.
        let rect: CGRect
        /// Bottom of regular letters on this line (y), used to align pieces and words.
        let baseline: CGFloat
        /// Extra scale for this piece, e.g. a drop cap shrunk to a normal capital.
        var scale: CGFloat = 1
    }

    let pieces: [Piece]
    /// Starts a new row: paragraph start, heading, or after a short line.
    let startsLine: Bool
}

nonisolated struct ReflowParagraph: Sendable {
    let words: [ReflowWord]
    /// Typical letter height in PDF points, used to pick the zoom factor.
    let letterHeight: CGFloat
}

/// Splits a card's PDF regions into words using per-character bounds.
nonisolated enum ReflowExtractor {
    /// `cardText` is the card's extracted text; rows that don't belong to it are dropped.
    static func paragraph(for regions: [PDFRegion], in document: PDFDocument, cardText: String? = nil) -> ReflowParagraph {
        let cardKey = cardText.map(searchKey)
        /// Rows above the first matching row (section headings) are kept; later strays are not.
        var seenCardText = false
        var words: [ReflowWord] = []
        var letterHeights: [CGFloat] = []
        var previousLineWasShort = false
        /// Glyphs of the previous line's last word, to strip a line-end hyphen.
        var previousLastWord: [Glyph] = []

        for region in regions {
            guard let page = document.page(at: region.pageIndex),
                  let selection = page.selection(for: region.rect)
            else {
                continue
            }
            // Regions are padded by 3pt around the column.
            let columnLeft = region.rect.minX + 3
            let columnRight = region.rect.maxX - 3

            var lineGlyphs: [[Glyph]] = []
            for line in selection.selectionsByLine() {
                let range = line.range(at: 0, on: page)
                guard range.location != NSNotFound, range.length > 0 else { continue }
                lineGlyphs.append(glyphs(in: range, page: page))
            }
            let inkRect = lineGlyphs.joined().map(\.box).filter { !$0.isNull }
                .reduce(region.rect) { $0.union($1) }
                .intersection(page.bounds(for: .mediaBox))
            let ink = InkMap(page: page, rect: inkRect)
            let regionHeight = median(lineGlyphs.flatMap { $0.filter(\.isLetter).map(\.box.height) }) ?? 10
            // Beside a drop cap or a tall symbol (√), PDFKit can report every glyph on the line
            // with an inflated height. The real line sits at the top or the bottom of that box:
            // pick the side that doesn't overlap the normal lines around it.
            let normalBands: [ClosedRange<CGFloat>] = lineGlyphs.compactMap { line in
                let boxes = line.filter(\.isLetter).map(\.box)
                guard let height = median(boxes.map(\.height)), height <= regionHeight * 1.3,
                      let low = median(boxes.map(\.minY)) else { return nil }
                return low...(low + height)
            }
            // How far a normal line's glyph boxes reach above and below its baseline.
            var ascents: [CGFloat] = [], descents: [CGFloat] = []
            for line in lineGlyphs {
                let boxes = line.filter(\.isLetter).map(\.box)
                guard let top = median(boxes.map(\.maxY)), let bottom = median(boxes.map(\.minY)),
                      boxes.allSatisfy({ $0.height <= regionHeight * 1.3 }),
                      let baseline = ink?.line(in: union(boxes))?.baseline else { continue }
                ascents.append(top - baseline)
                descents.append(baseline - bottom)
            }
            let normalAscent = median(ascents) ?? regionHeight * 0.8
            let normalDescent = median(descents) ?? regionHeight * 0.3
            func overlap(_ range: ClosedRange<CGFloat>) -> CGFloat {
                normalBands.reduce(0) { $0 + max(0, min($1.upperBound, range.upperBound) - max($1.lowerBound, range.lowerBound)) }
            }
            let rows = lineGlyphs.flatMap { line in
                visualRows(line.enumerated().map { offset, glyph in
                    let isDropCap = offset == 0 && glyph.isLetter && glyph.box.height > regionHeight * 1.8
                    guard !isDropCap, !glyph.box.isNull, glyph.box.height > regionHeight * 1.3 else { return glyph }
                    let box = glyph.box
                    // Best: the largest part of the box not covered by neighboring lines.
                    if let free = largestGap(in: box.minY...box.maxY, excluding: normalBands),
                       free.upperBound - free.lowerBound >= regionHeight * 0.8 {
                        let height = min(free.upperBound - free.lowerBound, regionHeight * 1.6)
                        let y = free.upperBound - height
                        return Glyph(character: glyph.character, box: CGRect(x: box.minX, y: y, width: box.width, height: height), isEstimated: true)
                    }
                    // Otherwise the end (top or bottom) that overlaps the neighbors less.
                    let height = regionHeight * 1.2
                    let top = (box.maxY - height)...box.maxY
                    let bottom = box.minY...(box.minY + height)
                    let y = overlap(bottom) < overlap(top) ? bottom.lowerBound : top.lowerBound
                    return Glyph(character: glyph.character, box: CGRect(x: box.minX, y: y, width: box.width, height: height), isEstimated: true)
                })
            }
            var previousRow: CGRect?
            /// A drop cap's glyph box, waiting for the row it starts.
            var dropCap: CGRect?

            for row in readingOrder(rows, tolerance: regionHeight * 0.5) {
                var glyphs = row
                // A drop cap spans several lines; shrink it to a capital and attach it to the next word.
                if let first = glyphs.first, first.isLetter, first.box.height > regionHeight * 1.8 {
                    dropCap = first.box
                    glyphs.removeFirst()
                }
                guard !glyphs.isEmpty else { continue }

                // Region selections also pick up neighboring lines whose glyph boxes reach into
                // the region (e.g. a line with a tall √ from the next card). Skip rows not in this card.
                if let cardKey {
                    let rowKey = searchKey(String(utf16CodeUnits: glyphs.filter { !$0.box.isNull }.map(\.character),
                                                  count: glyphs.filter { !$0.box.isNull }.count))
                    if rowKey.count >= 6 {
                        if belongs(rowKey, to: cardKey) {
                            seenCardText = true
                        } else if seenCardText {
                            dropCap = nil
                            continue
                        }
                    }
                }

                let letters = glyphs.filter(\.isLetter).map(\.box)
                letterHeights += letters.map(\.height)
                let rowRect = union(glyphs.map(\.box).filter { !$0.isNull })
                // The baseline from the ink, so rows whose glyph boxes were inflated still line up.
                let inkLine = ink?.line(in: rowRect)
                let baseline = inkLine?.baseline
                    ?? mostCommon(letters.map { ($0.minY * 2).rounded() / 2 }) ?? rowRect.minY
                let typicalHeight = median(letters.map(\.height)) ?? regionHeight

                let groups = group(glyphs, gapLimit: typicalHeight * 0.3)
                // Estimated boxes reach into the gaps between lines; keep a normal line's height
                // around the baseline so the row isn't spaced further apart than the others.
                let isEstimated = inkLine != nil && glyphs.contains(where: \.isEstimated)
                var lineWords = groups.map { word in
                    var rect = union(word.map(\.box))
                    if isEstimated {
                        rect = rect.intersection(CGRect(
                            x: rect.minX, y: baseline - normalDescent,
                            width: rect.width, height: normalDescent + normalAscent
                        ))
                    }
                    return ReflowWord(
                        pieces: [ReflowWord.Piece(pageIndex: region.pageIndex, rect: rect, baseline: baseline)],
                        startsLine: false
                    )
                }

                // A fragment to the right on the same row ("Encoder:" + "The encoder …") continues it.
                let continuesRow = previousRow.map {
                    abs($0.midY - rowRect.midY) < typicalHeight * 0.5 && rowRect.minX >= $0.maxX - 1
                } ?? false
                // Paragraph indents are small; text wrapped around a drop cap is indented further.
                let indent = rowRect.minX - columnLeft
                // Rows sharing the previous row's indent (text wrapped beside a drop cap) continue it.
                let sameIndentAsAbove = previousRow.map { abs($0.minX - rowRect.minX) < 2 } ?? false
                let indented = indent > 4 && indent < 18 && !sameIndentAsAbove
                if words.isEmpty || (!continuesRow && (indented || previousLineWasShort)) {
                    lineWords[0] = ReflowWord(pieces: lineWords[0].pieces, startsLine: true)
                }
                previousLineWasShort = rowRect.maxX < columnLeft + (columnRight - columnLeft) * 0.85

                if let capBox = dropCap {
                    // Crop the letter to its ink (its box also catches marks from the lines below)
                    // and shrink it to the height of a capital on this row.
                    let letter = ink?.glyphBounds(in: capBox)
                    let capHeight = inkLine.map { $0.top - $0.baseline } ?? regionHeight * 0.6
                    let cap = ReflowWord.Piece(
                        pageIndex: region.pageIndex,
                        rect: letter?.insetBy(dx: -0.5, dy: 0) ?? capBox,
                        baseline: letter?.minY ?? capBox.minY,
                        scale: capHeight / (letter?.height ?? capBox.height)
                    )
                    lineWords[0] = ReflowWord(pieces: [cap] + lineWords[0].pieces, startsLine: lineWords[0].startsLine)
                    dropCap = nil
                }

                // Join "hetero-" + "geneous" across the line break, dropping the hyphen.
                if !continuesRow, let last = words.last, let lastPiece = last.pieces.last,
                   !lineWords[0].startsLine,
                   previousLastWord.last?.isHyphen == true,
                   case let stemGlyphs = Array(previousLastWord.reversed().drop(while: \.isHyphen).reversed()),
                   !stemGlyphs.isEmpty,
                   groups.first?.first?.isLowercase == true,
                   let first = lineWords[0].pieces.first {
                    let stem = ReflowWord.Piece(
                        pageIndex: lastPiece.pageIndex,
                        rect: union(stemGlyphs.map(\.box)),
                        baseline: lastPiece.baseline
                    )
                    words[words.count - 1] = ReflowWord(
                        pieces: last.pieces.dropLast() + [stem, first],
                        startsLine: last.startsLine
                    )
                    lineWords.removeFirst()
                }
                previousLastWord = groups.last ?? []
                previousRow = rowRect
                words += lineWords
            }
        }
        return ReflowParagraph(words: words, letterHeight: median(letterHeights) ?? 10)
    }

    /// PDFKit sometimes returns two visual lines as one (e.g. beside a drop cap).
    /// Split where the text jumps vertically or back to the left.
    private static func visualRows(_ glyphs: [Glyph]) -> [[Glyph]] {
        let height = median(glyphs.filter(\.isLetter).map(\.box.height)) ?? 10
        var rows: [[Glyph]] = []
        var current: [Glyph] = []
        var lastBox: CGRect?
        for glyph in glyphs {
            if glyph.box.isNull {
                current.append(glyph)
                continue
            }
            if let last = lastBox,
               abs(glyph.box.midY - last.midY) > height * 0.8 || glyph.box.minX < last.minX - height {
                rows.append(current)
                current = []
            }
            current.append(glyph)
            lastBox = glyph.box
        }
        rows.append(current)
        return rows.map { row in
            Array(row.drop { $0.box.isNull }.reversed().drop { $0.box.isNull }.reversed())
        }.filter { !$0.isEmpty }
    }

    /// Top to bottom; fragments sharing a row are ordered left to right.
    private static func readingOrder(_ rows: [[Glyph]], tolerance: CGFloat) -> [[Glyph]] {
        // Spaces carry a null box, so only real glyphs count.
        let top: ([Glyph]) -> CGFloat = { $0.filter { !$0.box.isNull }.map(\.box.maxY).max() ?? 0 }
        let left: ([Glyph]) -> CGFloat = { $0.filter { !$0.box.isNull }.map(\.box.minX).min() ?? 0 }
        var ordered: [[Glyph]] = []
        var bucket: [[Glyph]] = []
        for row in rows.sorted(by: { top($0) > top($1) }) {
            if let first = bucket.first, top(first) - top(row) > tolerance {
                ordered += bucket.sorted { left($0) < left($1) }
                bucket = []
            }
            bucket.append(row)
        }
        return ordered + bucket.sorted { left($0) < left($1) }
    }

    /// The longest stretch of `range` left after removing `bands`.
    private static func largestGap(in range: ClosedRange<CGFloat>, excluding bands: [ClosedRange<CGFloat>]) -> ClosedRange<CGFloat>? {
        var gaps = [range]
        for band in bands {
            gaps = gaps.flatMap { gap -> [ClosedRange<CGFloat>] in
                guard band.upperBound > gap.lowerBound, band.lowerBound < gap.upperBound else { return [gap] }
                var pieces: [ClosedRange<CGFloat>] = []
                if band.lowerBound > gap.lowerBound { pieces.append(gap.lowerBound...band.lowerBound) }
                if band.upperBound < gap.upperBound { pieces.append(band.upperBound...gap.upperBound) }
                return pieces
            }
        }
        return gaps.max { ($0.upperBound - $0.lowerBound) < ($1.upperBound - $1.lowerBound) }
    }

    /// Letters and digits only, lowercased, with ligatures decomposed ("ﬁ" → "fi").
    private static func searchKey(_ text: String) -> String {
        String(text.precomposedStringWithCompatibilityMapping.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Most 8-character chunks of the row appear in the card, tolerating small extraction differences.
    private static func belongs(_ rowKey: String, to cardKey: String) -> Bool {
        let characters = Array(rowKey)
        let chunks = stride(from: 0, to: characters.count, by: 8).map {
            String(characters[$0..<min($0 + 8, characters.count)])
        }.filter { $0.count >= 4 }
        guard !chunks.isEmpty else { return true }
        return Double(chunks.filter { cardKey.contains($0) }.count) >= Double(chunks.count) * 0.5
    }

    // MARK: Glyphs

    struct Glyph {
        let character: unichar
        let box: CGRect
        /// The box was inflated by PDFKit and estimated from the lines around it.
        var isEstimated = false

        var isLetter: Bool {
            UnicodeScalar(character).map { CharacterSet.letters.contains($0) } ?? false
        }
        var isLowercase: Bool {
            UnicodeScalar(character).map { CharacterSet.lowercaseLetters.contains($0) } ?? false
        }
        var isHyphen: Bool {
            character == 0x2D || character == 0x2010
        }
    }

    /// Reads each character and its bounds from the same one-character selection.
    /// `page.string` indices can drift from glyph indices (ligatures), so they aren't mixed.
    private static func glyphs(in range: NSRange, page: PDFPage) -> [Glyph] {
        var result: [Glyph] = []
        for index in range.location..<NSMaxRange(range) {
            guard let selection = page.selection(for: NSRange(location: index, length: 1)),
                  let string = selection.string, let character = string.utf16.first
            else {
                continue
            }
            if string.allSatisfy(\.isWhitespace) {
                result.append(Glyph(character: 0x20, box: .null))
                continue
            }
            let box = selection.bounds(for: page)
            guard box.width > 0, box.height > 0 else { continue }
            // PDFKit can report a line-end character twice at the same position.
            if let previous = result.last, previous.character == character, previous.box == box {
                continue
            }
            result.append(Glyph(character: character, box: box))
        }
        return result
    }

    /// Splits at spaces and at visible gaps wider than `gapLimit`.
    private static func group(_ glyphs: [Glyph], gapLimit: CGFloat) -> [[Glyph]] {
        var words: [[Glyph]] = []
        var current: [Glyph] = []
        for glyph in glyphs {
            if glyph.box.isNull {
                if !current.isEmpty { words.append(current) }
                current = []
                continue
            }
            if let previous = current.last, glyph.box.minX - previous.box.maxX > gapLimit {
                words.append(current)
                current = []
            }
            current.append(glyph)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    // MARK: Ink

    /// A grayscale rendering of a region, to measure where ink actually is.
    /// Glyph boxes from PDFKit include line spacing and can be inflated; ink is exact.
    struct InkMap {
        private let pixels: [UInt8]
        private let width: Int
        private let height: Int
        private let rect: CGRect
        private let scale: CGFloat

        init?(page: PDFPage, rect: CGRect, scale: CGFloat = 4) {
            let width = Int((rect.width * scale).rounded(.up))
            let height = Int((rect.height * scale).rounded(.up))
            guard width > 0, height > 0 else { return nil }
            var pixels = [UInt8](repeating: 255, count: width * height)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return false }
                // Bitmap row 0 is the top; PDF y grows upward.
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: -rect.minX, y: -rect.minY)
                page.draw(with: .mediaBox, to: context)
                return true
            }
            guard drawn else { return nil }
            self.pixels = pixels
            self.width = width
            self.height = height
            self.rect = rect
            self.scale = scale
        }

        /// Ink pixels per pixel row inside `box`, from the top of the box down.
        private func rowCounts(in box: CGRect) -> (counts: [Int], top: Int, left: Int, right: Int)? {
            let left = max(0, Int(((box.minX - rect.minX) * scale).rounded(.down)))
            let right = min(width, Int(((box.maxX - rect.minX) * scale).rounded(.up)))
            let top = max(0, Int(((rect.maxY - box.maxY) * scale).rounded(.down)))
            let bottom = min(height, Int(((rect.maxY - box.minY) * scale).rounded(.up)))
            guard left < right, top < bottom else { return nil }
            let counts = (top..<bottom).map { y in
                (left..<right).reduce(0) { $0 + (pixels[y * width + $1] < 160 ? 1 : 0) }
            }
            return (counts, top, left, right)
        }

        private func pageY(ofRow row: Int) -> CGFloat {
            rect.maxY - CGFloat(row) / scale
        }

        /// The text baseline of a line inside `box`: the bottom of its densest band of ink.
        /// Descenders are sparse, so the count drops sharply right below the baseline.
        /// Returns the baseline and the top of the line's ink.
        func line(in box: CGRect) -> (baseline: CGFloat, top: CGFloat)? {
            guard let (counts, top, _, _) = rowCounts(in: box),
                  let peak = counts.indices.max(by: { counts[$0] < counts[$1] }), counts[peak] > 0
            else { return nil }
            var bottom = peak
            while bottom + 1 < counts.count, counts[bottom + 1] >= counts[peak] / 4 { bottom += 1 }
            var inkTop = peak
            while inkTop > 0, counts[inkTop - 1] > 0 { inkTop -= 1 }
            return (pageY(ofRow: top + bottom + 1), pageY(ofRow: top + inkTop))
        }

        /// The tight bounds of the tallest unbroken run of ink rows in `box`,
        /// leaving out stray marks above or below it.
        func glyphBounds(in box: CGRect) -> CGRect? {
            guard let (counts, top, left, right) = rowCounts(in: box) else { return nil }
            var best: Range<Int>?
            var start: Int?
            for (index, count) in (counts + [0]).enumerated() {
                if count > 0, start == nil { start = index }
                if count == 0, let first = start {
                    if (index - first) > (best?.count ?? 0) { best = first..<index }
                    start = nil
                }
            }
            guard let best else { return nil }
            var minX = right, maxX = left
            for y in best {
                for x in left..<right where pixels[(top + y) * width + x] < 160 {
                    minX = min(minX, x)
                    maxX = max(maxX, x + 1)
                }
            }
            guard minX < maxX else { return nil }
            return CGRect(
                x: rect.minX + CGFloat(minX) / scale,
                y: pageY(ofRow: top + best.upperBound),
                width: CGFloat(maxX - minX) / scale,
                height: CGFloat(best.count) / scale
            )
        }
    }

    // MARK: Helpers

    private static func union(_ boxes: [CGRect]) -> CGRect {
        boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
    }

    private static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
    }

    private static func mostCommon(_ values: [CGFloat]) -> CGFloat? {
        var counts: [CGFloat: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        // Ties broken by value so the result is deterministic.
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }
}
