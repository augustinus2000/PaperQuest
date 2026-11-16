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
    static func paragraph(for regions: [PDFRegion], in document: PDFDocument) -> ReflowParagraph {
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
            let regionHeight = median(lineGlyphs.flatMap { $0.filter(\.isLetter).map(\.box.height) }) ?? 10
            // Beside a drop cap, PDFKit reports every glyph with the drop cap's height.
            // Keep the drop cap itself, and clamp the others to a normal line at the top.
            let rows = lineGlyphs.flatMap { line in
                visualRows(line.enumerated().map { offset, glyph in
                    let isDropCap = offset == 0 && glyph.isLetter
                    guard !isDropCap, !glyph.box.isNull, glyph.box.height > regionHeight * 1.8 else { return glyph }
                    let box = glyph.box
                    return Glyph(
                        character: glyph.character,
                        box: CGRect(x: box.minX, y: box.maxY - regionHeight, width: box.width, height: regionHeight)
                    )
                })
            }
            var previousRow: CGRect?
            var dropCap: ReflowWord.Piece?

            for row in readingOrder(rows, tolerance: regionHeight * 0.5) {
                var glyphs = row
                // A drop cap spans several lines; shrink it to a capital and attach it to the next word.
                if let first = glyphs.first, first.isLetter, first.box.height > regionHeight * 1.8 {
                    dropCap = ReflowWord.Piece(
                        pageIndex: region.pageIndex, rect: first.box, baseline: first.box.minY,
                        scale: regionHeight / first.box.height
                    )
                    glyphs.removeFirst()
                }
                guard !glyphs.isEmpty else { continue }

                let letters = glyphs.filter(\.isLetter).map(\.box)
                letterHeights += letters.map(\.height)
                let rowRect = union(glyphs.map(\.box).filter { !$0.isNull })
                let baseline = mostCommon(letters.map { ($0.minY * 2).rounded() / 2 }) ?? rowRect.minY
                let typicalHeight = median(letters.map(\.height)) ?? regionHeight

                let groups = group(glyphs, gapLimit: typicalHeight * 0.3)
                var lineWords = groups.map { word in
                    ReflowWord(
                        pieces: [ReflowWord.Piece(pageIndex: region.pageIndex, rect: union(word.map(\.box)), baseline: baseline)],
                        startsLine: false
                    )
                }

                // A fragment to the right on the same row ("Encoder:" + "The encoder …") continues it.
                let continuesRow = previousRow.map {
                    abs($0.midY - rowRect.midY) < typicalHeight * 0.5 && rowRect.minX >= $0.maxX - 1
                } ?? false
                // Paragraph indents are small; text wrapped around a drop cap is indented further.
                let indent = rowRect.minX - columnLeft
                let indented = indent > 4 && indent < 18
                if words.isEmpty || (!continuesRow && (indented || previousLineWasShort)) {
                    lineWords[0] = ReflowWord(pieces: lineWords[0].pieces, startsLine: true)
                }
                previousLineWasShort = rowRect.maxX < columnLeft + (columnRight - columnLeft) * 0.85

                if let cap = dropCap {
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

    // MARK: Glyphs

    struct Glyph {
        let character: unichar
        let box: CGRect

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
