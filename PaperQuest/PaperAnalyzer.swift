//
//  PaperAnalyzer.swift
//  PaperQuest
//
//  Created by 임준혁 on 7/17/26.
//

import CoreGraphics
import Foundation
import PDFKit

#if canImport(UIKit)
import UIKit
private typealias PlatformFont = UIFont
#else
import AppKit
private typealias PlatformFont = NSFont
#endif

/// PDF를 학습 카드로 나눈다.
///
/// `PDFPage.string`처럼 글자만 이어 붙이면 위치·크기 정보가 사라져
/// 머리글/각주가 본문에 섞이고 2단 순서가 꼬인다. 그래서 줄마다
/// 위치와 글자 크기를 읽어 다음 순서로 처리한다.
/// 1. 머리글·바닥글·세로 스탬프 제거, 같은 줄 조각 합치기
/// 2. 단(column) 감지 후 읽기 순서 정렬
/// 3. 캡션으로 그림·표 영역, 번호로 수식 영역 찾기
/// 4. 남은 본문 크기 줄을 들여쓰기·간격으로 문단으로 묶기 (단·페이지를 넘어가도 이어 붙임)
nonisolated enum PaperAnalyzer {
    static func analyze(paper: ImportedPaper) -> [PaperBlock] {
        LayoutAnalysis(document: paper.document).makeBlocks()
    }
}

// MARK: - Layout Model

nonisolated private enum Column {
    case left
    case right
    case span
}

nonisolated private struct Line {
    var id = 0
    let page: Int
    var text: String
    var rect: CGRect
    let fontSize: CGFloat
    var column: Column = .left
}

nonisolated private struct PageLayout {
    let index: Int
    let box: CGRect
    /// One range for single-column pages, two for two-column pages.
    let columns: [ClosedRange<CGFloat>]
    /// Lines in reading order.
    var lines: [Line]

    func range(for column: Column) -> ClosedRange<CGFloat> {
        switch column {
        case .left:
            return columns[0]
        case .right:
            return columns.count > 1 ? columns[1] : columns[0]
        case .span:
            return columns[0].lowerBound...columns[columns.count - 1].upperBound
        }
    }
}

nonisolated private enum CaptionKind {
    case figure
    case table
    case algorithm
}

nonisolated private struct VisualElement {
    let kind: CaptionKind
    /// Normalized label such as "fig:2" or "table:iii", used to find mentions.
    let key: String
    let mentionPattern: String
    let caption: String
    /// Algorithm pseudo-code text, for the explanation model.
    let content: String?
    let region: PDFRegion
    let position: Int
}

nonisolated private struct Equation {
    let lines: [Line]
    let region: PDFRegion
}

nonisolated private enum FlowItem {
    /// `heading` lines are shown above the paragraph's first card but are not part of its text.
    case paragraph([Line], heading: [Line], section: String?)
    case equation(Equation, section: String?)
}

// MARK: - Analysis

nonisolated private struct LayoutAnalysis {
    private var pages: [PageLayout] = []
    private var bodySize: CGFloat = 10
    /// Every line of every page in reading order.
    private var ordered: [Line] = []
    private var positionByID: [Int: Int] = [:]
    /// Hyphenated words that appear mid-line, e.g. "protocol-specific".
    private var hyphenatedForms = Set<String>()

    init(document: PDFDocument) {
        var raw: [(index: Int, box: CGRect, lines: [Line])] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let box = page.bounds(for: .mediaBox)
            raw.append((index, box, Self.extractLines(from: page, index: index, box: box)))
        }

        bodySize = Self.dominantSize(of: raw.flatMap(\.lines))
        let repeatedMargins = Self.repeatedMarginTexts(in: raw)

        var nextID = 0
        var built: [PageLayout] = []
        for page in raw {
            var lines = page.lines.filter {
                !isMarginNoise($0, box: page.box, repeated: repeatedMargins)
            }
            lines = Self.mergeRowFragments(lines, box: page.box)
            for index in lines.indices {
                lines[index].id = nextID
                nextID += 1
            }
            built.append(layoutPage(index: page.index, box: page.box, lines: lines))
        }

        // Pages made only of figures fall back to the layout seen elsewhere.
        let fallback = built.first { $0.columns.count == 2 }?.columns
        pages = built.map { page in
            // A last page whose right column holds only small reference text still reads in two columns.
            if page.columns.count == 1, let fallback, isMostlyNarrow(page) {
                return layoutPage(index: page.index, box: page.box, lines: page.lines, columns: fallback)
            }
            guard page.columns.isEmpty else { return page }
            let columns = fallback ?? [page.box.minX + 40...page.box.maxX - 40]
            return layoutPage(index: page.index, box: page.box, lines: page.lines, columns: columns)
        }

        ordered = pages.flatMap(\.lines)
        for (position, line) in ordered.enumerated() {
            positionByID[line.id] = position
        }
        for line in ordered {
            for match in Self.matches(of: #"[A-Za-z]+-[A-Za-z]+"#, in: line.text) {
                hyphenatedForms.insert(match.lowercased())
            }
        }
    }

    // MARK: Line Extraction

    private static func extractLines(from page: PDFPage, index: Int, box: CGRect) -> [Line] {
        guard let selection = page.selection(for: box) else { return [] }
        return selection.selectionsByLine().compactMap { lineSelection in
            let text = normalizeWhitespace(lineSelection.string ?? "")
            let rect = lineSelection.bounds(for: page)
            guard !text.isEmpty, rect.width > 0.5, rect.height > 0.5 else { return nil }
            return Line(
                page: index,
                text: text,
                rect: rect,
                fontSize: dominantFontSize(of: lineSelection)
            )
        }
    }

    /// The size covering the most characters, so a drop cap doesn't win.
    private static func dominantFontSize(of selection: PDFSelection) -> CGFloat {
        guard let attributed = selection.attributedString, attributed.length > 0 else { return 0 }
        var weights: [CGFloat: Int] = [:]
        attributed.enumerateAttribute(
            .font, in: NSRange(location: 0, length: attributed.length)
        ) { value, range, _ in
            guard let font = value as? PlatformFont else { return }
            weights[(font.pointSize * 2).rounded() / 2, default: 0] += range.length
        }
        return mostCommonSize(in: weights) ?? 0
    }

    /// Dictionary order is randomized per process, so ties must be broken explicitly.
    /// Prefer the larger size: in a math-heavy line, body text and subscripts can tie.
    private static func mostCommonSize(in weights: [CGFloat: Int]) -> CGFloat? {
        weights.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key
    }

    private static func dominantSize(of lines: [Line]) -> CGFloat {
        var weights: [CGFloat: Int] = [:]
        for line in lines where line.fontSize > 0 {
            weights[line.fontSize, default: 0] += line.text.count
        }
        return mostCommonSize(in: weights) ?? 10
    }

    // MARK: Margins

    private static func marginKey(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"[0-9]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func isInMarginBand(_ rect: CGRect, box: CGRect, fraction: CGFloat) -> Bool {
        rect.minY > box.maxY - box.height * fraction || rect.maxY < box.minY + box.height * fraction
    }

    /// Running heads and footers repeat on many pages, unlike body text.
    private static func repeatedMarginTexts(
        in pages: [(index: Int, box: CGRect, lines: [Line])]
    ) -> Set<String> {
        var counts: [String: Int] = [:]
        for page in pages {
            let keys = Set(
                page.lines
                    .filter { isInMarginBand($0.rect, box: page.box, fraction: 0.1) }
                    .map { marginKey($0.text) }
                    .filter { $0.count >= 4 }
            )
            for key in keys {
                counts[key, default: 0] += 1
            }
        }
        let threshold = max(2, Int((Double(pages.count) * 0.3).rounded()))
        return Set(counts.filter { $0.value >= threshold }.keys)
    }

    private func isMarginNoise(_ line: Line, box: CGRect, repeated: Set<String>) -> Bool {
        // Vertical text such as the arXiv identifier stamp.
        if line.rect.height > line.rect.width * 2, line.rect.height > 40 {
            return true
        }
        let inTopBand = line.rect.minY > box.maxY - box.height * 0.075
        let inBottomBand = line.rect.maxY < box.minY + box.height * 0.06
        guard inTopBand || inBottomBand else { return false }
        if repeated.contains(Self.marginKey(line.text)) {
            return true
        }
        if Self.matches(line.text, #"^\d{1,4}$"#) {
            return true
        }
        return line.fontSize > 0 && line.fontSize < bodySize * 0.9
    }

    // MARK: Page Layout

    /// PDFKit sometimes splits one visual line into fragments ("Fig. 1." + caption).
    private static func mergeRowFragments(_ lines: [Line], box: CGRect) -> [Line] {
        let sorted = lines.sorted {
            $0.rect.midY != $1.rect.midY ? $0.rect.midY > $1.rect.midY : $0.rect.minX < $1.rect.minX
        }
        var merged: [Line] = []
        for line in sorted {
            let candidate = merged.lastIndex { other in
                let sameRow = abs(other.rect.midY - line.rect.midY)
                    <= min(other.rect.height, line.rect.height) * 0.45
                let gap = line.rect.minX - other.rect.maxX
                let crossesGutter = other.rect.maxX <= box.midX && line.rect.minX >= box.midX
                return sameRow && gap >= -1 && gap < 12 && !crossesGutter
            }
            if let candidate {
                merged[candidate].text += " " + line.text
                merged[candidate].rect = merged[candidate].rect.union(line.rect)
            } else {
                merged.append(line)
            }
        }
        return merged
    }

    /// Most body lines fit inside half the page, so the page is set in columns.
    private func isMostlyNarrow(_ page: PageLayout) -> Bool {
        let body = page.lines.filter { isProseSize($0) && $0.rect.width > page.box.width * 0.2 }
        guard body.count >= 6 else { return false }
        let narrow = body.filter { $0.rect.width < page.box.width * 0.55 }
        return Double(narrow.count) >= Double(body.count) * 0.8
    }

    private func isProseSize(_ line: Line) -> Bool {
        line.fontSize == 0 || (line.fontSize >= bodySize * 0.86 && line.fontSize <= bodySize * 1.15)
    }

    private func detectColumns(_ lines: [Line], box: CGRect) -> [ClosedRange<CGFloat>] {
        let body = lines.filter { isProseSize($0) && $0.rect.width > box.width * 0.2 }
        guard body.count >= 6 else { return [] }
        let mid = box.midX
        let left = body.filter { $0.rect.maxX <= mid + 8 }
        let right = body.filter { $0.rect.minX >= mid - 8 }
        if left.count >= 3, right.count >= 3,
           Double(left.count + right.count) >= Double(body.count) * 0.6 {
            return [
                left.map(\.rect.minX).min()!...left.map(\.rect.maxX).max()!,
                right.map(\.rect.minX).min()!...right.map(\.rect.maxX).max()!
            ]
        }
        return [body.map(\.rect.minX).min()!...body.map(\.rect.maxX).max()!]
    }

    private func layoutPage(
        index: Int, box: CGRect, lines: [Line], columns forced: [ClosedRange<CGFloat>]? = nil
    ) -> PageLayout {
        let columns = forced ?? detectColumns(lines, box: box)
        guard !columns.isEmpty else {
            return PageLayout(index: index, box: box, columns: [], lines: lines)
        }

        var assigned = lines
        for i in assigned.indices {
            let rect = assigned[i].rect
            if columns.count == 2 {
                if rect.maxX <= box.midX + 8 {
                    assigned[i].column = .left
                } else if rect.minX >= box.midX - 8 {
                    assigned[i].column = .right
                } else {
                    assigned[i].column = .span
                }
            } else {
                assigned[i].column = .left
            }
        }

        // Spanning items above all body text (title, wide figures) read first.
        // Labels inside a wide figure are short, so only sentence-like lines mark where body text begins.
        let bodyTop = assigned
            .filter { $0.column != .span && isProseSize($0) && isSentenceLike($0.text) }
            .map(\.rect.maxY).max() ?? box.maxY
        let topDown: (Line, Line) -> Bool = {
            $0.rect.maxY != $1.rect.maxY ? $0.rect.maxY > $1.rect.maxY : $0.rect.minX < $1.rect.minX
        }
        let spanTop = assigned.filter { $0.column == .span && $0.rect.minY >= bodyTop - 2 }
        let spanRest = assigned.filter { $0.column == .span && $0.rect.minY < bodyTop - 2 }
        let ordered = spanTop.sorted(by: topDown)
            + assigned.filter { $0.column == .left }.sorted(by: topDown)
            + assigned.filter { $0.column == .right }.sorted(by: topDown)
            + spanRest.sorted(by: topDown)
        return PageLayout(index: index, box: box, columns: columns, lines: ordered)
    }

    // MARK: Headings

    private func isHeading(_ line: Line, in page: PageLayout) -> Bool {
        let text = line.text
        let words = text.split(separator: " ").count
        // Small-caps headings ("I. INTRODUCTION") report a smaller dominant size, so allow down to 0.75.
        guard text.count <= 90, words <= 12,
              line.fontSize == 0 || (line.fontSize >= bodySize * 0.75 && line.fontSize <= bodySize * 1.8),
              !text.hasSuffix(","), !text.hasSuffix(";")
        else {
            return false
        }
        if words <= 5, Self.matches(
            text,
            #"(?i)^(?:[IVXL]+\.|\d+\.?)?\s*(abstract|introduction|related work|background|conclusions?|references|bibliography|acknowledge?ments?|appendix)\s*$"#
        ) {
            return true
        }
        let range = page.range(for: line.column)
        // Body lines are justified to the full column; headings stop short of it.
        let isShort = line.rect.width < (range.upperBound - range.lowerBound) * 0.93
        let isCentered = line.rect.minX - range.lowerBound > 8 && range.upperBound - line.rect.maxX > 8
        guard isShort || isCentered, !text.hasSuffix(".") else { return false }
        if Self.matches(text, #"^[IVXL]+\.\s+[A-Z]"#) || Self.matches(text, #"^[A-Z]\.\s+[A-Z][A-Za-z]"#) {
            return true
        }
        let isRegularSize = line.fontSize == 0 || line.fontSize >= bodySize * 0.95
        if isRegularSize, Self.matches(text, #"^\d+(\.\d+)*\.?\s+[A-Z]"#), words <= 10 {
            return true
        }
        return line.fontSize >= bodySize * 1.12 && words <= 10
    }

    /// "I." is either Roman numeral one or the subsection after "H.", so use the previous subsection letter.
    private func isTopLevelHeading(_ text: String, previousSubsection: Character?) -> Bool {
        if Self.matches(text, #"^\d+\.\d+"#) {
            return false
        }
        guard Self.matches(text, #"^[A-Z]\.\s"#), let letter = text.first else {
            return true
        }
        if letter == "A" {
            return false
        }
        if let previous = previousSubsection, let ascii = previous.asciiValue,
           letter == Character(UnicodeScalar(ascii + 1)) {
            return false
        }
        // Any other single letter is a subsection unless it reads as a Roman numeral (I, V, X, L).
        return Self.matches(text, #"^[IVXL]\.\s"#)
    }

    private func isReferencesHeading(_ text: String) -> Bool {
        Self.matches(text, #"(?i)^(?:[IVXL]+\.|\d+\.?)?\s*(references|bibliography)\s*$"#)
    }

    // MARK: Captions and Visual Regions

    private func captionKind(of line: Line) -> (kind: CaptionKind, key: String, mention: String)? {
        guard line.fontSize == 0 || line.fontSize <= bodySize + 0.3 else { return nil }
        let text = line.text
        if let number = Self.firstGroup(
            #"(?i)^(?:fig\.?|figure)\s*(\d+)[a-z]?\s*(?:[:.|—–]|-\s|$)"#, in: text
        ) {
            return (.figure, "fig:\(number)", #"(?i)\b(fig\.?|figure)\s*"# + number + #"(?![0-9])"#)
        }
        // IEEE uses an all-caps "TABLE II" line; other styles use "Table 2:".
        if let label = Self.firstGroup(#"^TABLE\s+([IVXLC]+|\d+)\b"#, in: text)
            ?? Self.firstGroup(#"(?i)^table\s+([ivxlc]+|\d+)[a-z]?\s*[:.|]"#, in: text) {
            return (.table, "table:\(label.lowercased())", #"(?i)\btable\s+"# + label + #"\b"#)
        }
        let isShortTitle = text.split(separator: " ").count <= 10 && !text.hasSuffix(".")
        if let number = Self.firstGroup(#"^Algorithm\s+(\d+)\s*[:.]"#, in: text)
            ?? (isShortTitle ? Self.firstGroup(#"^Algorithm\s+(\d+)\s+[A-Z]"#, in: text) : nil) {
            return (.algorithm, "algorithm:\(number)", #"(?i)\balgorithm\s+"# + number + #"(?![0-9])"#)
        }
        return nil
    }

    private func overlapsHorizontally(_ rect: CGRect, _ range: ClosedRange<CGFloat>) -> Bool {
        let overlap = min(rect.maxX, range.upperBound) - max(rect.minX, range.lowerBound)
        return overlap > min(rect.width, range.upperBound - range.lowerBound) * 0.3
    }

    /// Lines that bound a figure or table: wide body text, headings or other captions.
    /// Labels inside figures and algorithm pseudo-code are smaller or short, so they don't count.
    private func isObstacle(_ line: Line, in page: PageLayout, captionIDs: Set<Int>) -> Bool {
        if captionIDs.contains(line.id) || isHeading(line, in: page) {
            return true
        }
        let range = page.range(for: line.column)
        let isBodySize = line.fontSize == 0 || line.fontSize >= bodySize * 0.97
        return isBodySize
            && line.rect.width >= (range.upperBound - range.lowerBound) * 0.6
            && isSentenceLike(line.text)
    }

    /// Prose is mostly lowercase words; table rows are numbers, symbols and capitalized labels.
    private func isSentenceLike(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        guard words.count >= 5 else { return false }
        let lowercaseWords = words.filter { Self.matches(String($0), #"^[(\[]?[a-z][a-z'’-]*[)\],.;:]*$"#) }
        return Double(lowercaseWords.count) / Double(words.count) >= 0.5
    }

    private func captionLines(startingAt start: Line, in page: PageLayout) -> [Line] {
        var lines = [start]
        let span = page.range(for: start.column)
        let label = Self.firstMatch(
            #"(?i)^(?:fig\.?|figure|table|algorithm)\s*[ivxlc0-9]+[a-z]?\s*[:.|]?"#, in: start.text
        ) ?? ""
        var body = String(start.text.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
        // Algorithm captions are a single title line above the pseudo-code.
        let isAlgorithm = start.text.hasPrefix("Algorithm")
        // IEEE "TABLE" titles are small caps (upper case); the header row below is not.
        let isSmallCapsTitle = start.text.hasPrefix("TABLE")
        while !isAlgorithm, lines.count < 7, body.isEmpty || !(body.hasSuffix(".") || body.hasSuffix(":")) {
            let previous = lines[lines.count - 1]
            let next = page.lines
                .filter { candidate in
                    candidate.rect.maxY <= previous.rect.minY + 1
                        && previous.rect.minY - candidate.rect.maxY < max(previous.rect.height, candidate.rect.height) * 1.6
                        && overlapsHorizontally(candidate.rect, span)
                        && (candidate.fontSize == 0 || candidate.fontSize <= max(bodySize * 0.98, start.fontSize + 0.3))
                        && captionKind(of: candidate) == nil
                        && (isSmallCapsTitle
                            ? Self.lowercaseRatio(candidate.text) < 0.2
                                || (abs(candidate.rect.midX - start.rect.midX) < 3
                                    && previous.rect.minY - candidate.rect.maxY < max(previous.rect.height, candidate.rect.height) * 0.8)
                            // Caption lines share the first line's left edge (or center);
                            // table header rows below start elsewhere.
                            : abs(candidate.rect.minX - start.rect.minX) < 3
                                || abs(candidate.rect.midX - start.rect.midX) < 3)
                }
                .max { $0.rect.maxY < $1.rect.maxY }
            guard let next else { break }
            lines.append(next)
            body += " " + next.text
        }
        return lines
    }

    /// True when the line directly above is unfinished prose, as in "… summarized in" / "Table II.",
    /// which makes a caption-looking line a reference inside a sentence.
    private func continuesSentence(_ line: Line, in page: PageLayout) -> Bool {
        let above = page.lines
            .filter { $0.column == line.column && $0.rect.midY > line.rect.maxY }
            .min { $0.rect.minY < $1.rect.minY }
        guard let above, isProseSize(above) else { return false }
        let gap = above.rect.minY - line.rect.maxY
        return gap < bodySize * 0.8 && !Self.matches(above.text, #"[.?!:]$"#)
    }

    /// Finds the region between `edge` and the nearest obstacle above or below it.
    private func region(
        from edge: CGFloat,
        upward: Bool,
        span: ClosedRange<CGFloat>,
        in page: PageLayout,
        captionIDs: Set<Int>,
        excluding excluded: Set<Int>,
        isAlgorithm: Bool = false
    ) -> CGRect? {
        let obstacles = page.lines.filter { line in
            // Numbered pseudo-code lines, Require/Input headers and nested (deeply indented)
            // statements belong to the algorithm box.
            // Captions and headings still end the box.
            if isAlgorithm, !captionIDs.contains(line.id), !isHeading(line, in: page),
               Self.matches(line.text, #"^(\d{1,2}:?\s|(Require|Ensure|Input|Output)\b)"#)
                || line.rect.minX - page.range(for: line.column).lowerBound > 24 {
                return false
            }
            return !excluded.contains(line.id)
                && overlapsHorizontally(line.rect, span)
                && (upward ? line.rect.midY > edge : line.rect.midY < edge)
                && isObstacle(line, in: page, captionIDs: captionIDs)
        }
        let contentTop = page.box.maxY - page.box.height * 0.06
        let contentBottom = page.box.minY + page.box.height * 0.05
        let lower: CGFloat
        let upper: CGFloat
        if upward {
            lower = edge + 1
            upper = (obstacles.map(\.rect.minY).min() ?? contentTop) - 1
        } else {
            upper = edge - 1
            lower = (obstacles.map(\.rect.maxY).max() ?? contentBottom) + 1
        }
        guard upper - lower >= 24 else { return nil }
        return CGRect(
            x: span.lowerBound - 4,
            y: lower,
            width: span.upperBound - span.lowerBound + 8,
            height: upper - lower
        )
    }

    private func visualElements(
        in page: PageLayout
    ) -> (elements: [VisualElement], consumed: Set<Int>, regions: [CGRect]) {
        var captions: [(kind: CaptionKind, key: String, mention: String, lines: [Line])] = []
        var captionIDs = Set<Int>()
        for line in page.lines where !captionIDs.contains(line.id) {
            guard let kind = captionKind(of: line), !continuesSentence(line, in: page) else { continue }
            let lines = captionLines(startingAt: line, in: page)
            captionIDs.formUnion(lines.map(\.id))
            captions.append((kind.kind, kind.key, kind.mention, lines))
        }

        var elements: [VisualElement] = []
        var regions: [CGRect] = []
        for caption in captions {
            let first = caption.lines[0]
            let last = caption.lines[caption.lines.count - 1]
            let span = page.range(for: first.column)
            let ownIDs = Set(caption.lines.map(\.id))
            // Figures sit above their caption and tables below it; try the other side as a fallback.
            let above = region(from: first.rect.maxY, upward: true, span: span, in: page, captionIDs: captionIDs, excluding: ownIDs)
            let below = region(
                from: last.rect.minY, upward: false, span: span, in: page,
                captionIDs: captionIDs, excluding: ownIDs, isAlgorithm: caption.kind == .algorithm
            )
            guard let rect = caption.kind == .figure ? (above ?? below) : (below ?? above) else { continue }
            let inside = page.lines.filter {
                !ownIDs.contains($0.id) && rect.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY))
            }
            var shown = rect
            // Tables and algorithms end at their last text line plus room for the closing rule.
            if caption.kind != .figure, let lowest = inside.map(\.rect.minY).min() {
                let bottom = max(rect.minY, lowest - 6)
                shown = CGRect(x: rect.minX, y: bottom, width: rect.width, height: rect.maxY - bottom)
            }
            // Algorithm boxes also contain their title line.
            if caption.kind == .algorithm {
                shown = shown.union(first.rect.insetBy(dx: 0, dy: -3))
            }
            regions.append(shown)
            elements.append(
                VisualElement(
                    kind: caption.kind,
                    key: caption.key,
                    mentionPattern: caption.mention,
                    caption: joinLines(caption.lines),
                    content: caption.kind == .algorithm
                        ? String(inside.map(\.text).joined(separator: "\n").prefix(2_500)) : nil,
                    region: PDFRegion(pageIndex: page.index, rect: shown),
                    position: positionByID[first.id] ?? 0
                )
            )
        }

        var consumed = captionIDs
        for line in page.lines where regions.contains(where: { $0.contains(CGPoint(x: line.rect.midX, y: line.rect.midY)) }) {
            consumed.insert(line.id)
        }
        return (elements, consumed, regions)
    }

    // MARK: Equations

    private func isDisplayLike(_ line: Line, range: ClosedRange<CGFloat>) -> Bool {
        let width = range.upperBound - range.lowerBound
        return line.rect.minX - range.lowerBound > 12 && line.rect.width < width * 0.9
    }

    private func equations(in page: PageLayout, consumed: Set<Int>) -> [Equation] {
        var used = consumed
        var result: [Equation] = []

        for column in [Column.left, .right, .span] {
            let range = page.range(for: column)
            let width = range.upperBound - range.lowerBound
            let lines = page.lines.filter { $0.column == column && !used.contains($0.id) }

            func neighbors(of group: [Line]) -> (above: Line?, below: Line?) {
                let top = group.map(\.rect.maxY).max() ?? 0
                let bottom = group.map(\.rect.minY).min() ?? 0
                let ids = Set(group.map(\.id))
                let above = lines.filter { !ids.contains($0.id) && $0.rect.midY > top }.min { $0.rect.minY < $1.rect.minY }
                let below = lines.filter { !ids.contains($0.id) && $0.rect.midY < bottom }.max { $0.rect.maxY < $1.rect.maxY }
                return (above, below)
            }

            for line in lines where !used.contains(line.id) {
                let isNumber = Self.matches(line.text, #"^\(\d{1,3}[a-z]?\)$"#)
                    && line.rect.maxX >= range.upperBound - 20
                    && line.rect.minX > range.lowerBound + width * 0.6
                let hasMath = line.text.range(of: #"[=∑∏∈≤≥→∝‖×∫]"#, options: .regularExpression) != nil
                let isCenteredMath = line.rect.minX - range.lowerBound > 20
                    && line.rect.maxX < range.upperBound - 15
                    && line.rect.width < width * 0.8
                // The number can merge into the equation line when they sit close together;
                // an indented line ending in "(6)" at the column edge is an equation even without "=".
                let isNumberedMath = line.rect.minX - range.lowerBound > 20
                    && line.rect.maxX >= range.upperBound - 20
                    && Self.matches(line.text, #"\(\d{1,3}[a-z]?\)$"#)
                // Sub- and superscripts can make an equation line's dominant size small.
                let isMathSize = line.fontSize == 0 || line.fontSize >= bodySize * 0.6
                let isMathLine = isMathSize && ((hasMath && isCenteredMath) || isNumberedMath)
                // Figure exports sometimes embed LaTeX source as invisible text.
                guard isNumber || isMathLine, !line.text.contains("latexit") else { continue }

                // Start with every piece on the same row: "h′(t) = …,  y(t) = …  (3)".
                var group = [line]
                group += lines.filter {
                    $0.id != line.id && !used.contains($0.id)
                        && $0.rect.maxY >= line.rect.minY - 2 && $0.rect.minY <= line.rect.maxY + 2
                        && (isDisplayLike($0, range: range) || Self.matches($0.text, #"^\(\d{1,3}[a-z]?\)$"#))
                }
                // Grow through adjacent centered lines (multi-line equations).
                var grew = true
                while grew {
                    grew = false
                    let (above, below) = neighbors(of: group)
                    for candidate in [above, below].compactMap({ $0 }) where !used.contains(candidate.id) {
                        let gap = candidate.rect.midY > group[0].rect.midY
                            ? candidate.rect.minY - (group.map(\.rect.maxY).max() ?? 0)
                            : (group.map(\.rect.minY).min() ?? 0) - candidate.rect.maxY
                        if gap < bodySize * 1.2, isDisplayLike(candidate, range: range),
                           !Self.matches(candidate.text, #"^\(\d{1,3}[a-z]?\)$"#) {
                            group.append(candidate)
                            grew = true
                        }
                    }
                }
                // Sub/superscript rows sit inside the equation's height, neither above nor below it.
                let groupIDs = Set(group.map(\.id))
                let groupTop = group.map(\.rect.maxY).max()!
                let groupBottom = group.map(\.rect.minY).min()!
                group += lines.filter {
                    !groupIDs.contains($0.id) && !used.contains($0.id)
                        && $0.rect.midY < groupTop && $0.rect.midY > groupBottom
                        && isDisplayLike($0, range: range)
                }
                guard group.count > 1 || !isNumber else { continue }

                let top = group.map(\.rect.maxY).max()!
                let bottom = group.map(\.rect.minY).min()!
                let (above, below) = neighbors(of: group)
                // Extend toward neighbors so tall symbols outside line bounds aren't clipped.
                // Extend toward neighbors for tall symbols, but stay clear of them: their line
                // bounds don't fully cover descenders. Tight gaps may trim the equation's own padding.
                let upper = max(top - 4, min(above.map { $0.rect.minY - 3 } ?? top + 6, top + 12))
                let lower = min(bottom + 4, max(below.map { $0.rect.maxY + 3 } ?? bottom - 6, bottom - 12))
                let rect = CGRect(x: range.lowerBound - 4, y: lower, width: width + 8, height: upper - lower)
                used.formUnion(group.map(\.id))
                result.append(
                    Equation(
                        lines: group.sorted { $0.rect.maxY != $1.rect.maxY ? $0.rect.maxY > $1.rect.maxY : $0.rect.minX < $1.rect.minX },
                        region: PDFRegion(pageIndex: page.index, rect: rect)
                    )
                )
            }
        }
        return result
    }

    // MARK: Text

    private func joinLines(_ lines: [Line]) -> String {
        var text = ""
        for line in lines {
            text = text.isEmpty ? line.text : join(text, line.text)
        }
        return text
    }

    /// Joins wrapped lines, dropping hyphens only where the word isn't hyphenated elsewhere.
    private func join(_ head: String, _ tail: String) -> String {
        guard head.hasSuffix("-"), !head.hasSuffix(" -"), let first = tail.first else {
            return head + " " + tail
        }
        let fragment = head.dropLast().split(separator: " ").last.map(String.init) ?? ""
        let next = tail.prefix { $0.isLetter }
        // Keep the hyphen in compounds ("state-of-the-art", "service-Oriented") and known hyphenated words.
        if !first.isLowercase || fragment.contains("-")
            || hyphenatedForms.contains("\(fragment)-\(next)".lowercased()) {
            return head + tail
        }
        return String(head.dropLast()) + tail
    }

    private func region(for lines: [Line]) -> [PDFRegion] {
        var regions: [PDFRegion] = []
        var group: [Line] = []

        func flush() {
            guard let first = group.first, let page = pages.first(where: { $0.index == first.page }) else { return }
            let range = page.range(for: first.column)
            let top = group.map(\.rect.maxY).max()! + 1
            let bottom = group.map(\.rect.minY).min()! - 1
            let left = min(range.lowerBound, group.map(\.rect.minX).min()!) - 3
            let right = max(range.upperBound, group.map(\.rect.maxX).max()!) + 3
            regions.append(
                PDFRegion(pageIndex: first.page, rect: CGRect(x: left, y: bottom, width: right - left, height: top - bottom))
            )
            group = []
        }

        for line in lines {
            if let last = group.last, last.page != line.page || last.column != line.column {
                flush()
            }
            group.append(line)
        }
        flush()
        return regions
    }

    /// Splits long paragraphs at sentence ends so a card stays readable.
    private func chunks(of lines: [Line]) -> [[Line]] {
        guard lines.reduce(0, { $0 + $1.text.count }) > 1_100 else { return [lines] }
        var result: [[Line]] = []
        var current: [Line] = []
        var length = 0
        for line in lines {
            current.append(line)
            length += line.text.count
            if length >= 600, Self.matches(line.text, #"[.?!][)”"]?$"#) {
                result.append(current)
                current = []
                length = 0
            }
        }
        if !current.isEmpty {
            if length < 250, !result.isEmpty {
                result[result.count - 1] += current
            } else {
                result.append(current)
            }
        }
        return result
    }

    // MARK: Flow

    func makeBlocks() -> [PaperBlock] {
        var consumed = Set<Int>()
        var visuals: [VisualElement] = []
        var equationByFirstID: [Int: Equation] = [:]
        for page in pages where !page.columns.isEmpty {
            let found = visualElements(in: page)
            visuals += found.elements
            consumed.formUnion(found.consumed)
            for equation in equations(in: page, consumed: consumed) {
                let first = equation.lines.min { (positionByID[$0.id] ?? 0) < (positionByID[$1.id] ?? 0) }!
                equationByFirstID[first.id] = equation
                consumed.formUnion(equation.lines.map(\.id))
            }
        }

        let pageByIndex = Dictionary(uniqueKeysWithValues: pages.map { ($0.index, $0) })
        // Start at the abstract when there is one, so titles and notices are skipped.
        let start = ordered.firstIndex { Self.matches($0.text, #"(?i)^abstract\b"#) }
            ?? ordered.firstIndex { line in
                pageByIndex[line.page].map { isHeading(line, in: $0) } ?? false
            }
            ?? 0

        var items: [FlowItem] = []
        var paragraph: [Line] = []
        var topSection: String?
        var subSection: String?
        var section: String? {
            [topSection, subSection].compactMap { $0 }.joined(separator: " › ").nilIfEmpty
        }
        var stopPosition = ordered.count
        /// Heading waiting for the paragraph that follows it.
        var pendingHeading: [Line] = []
        var paragraphHeading: [Line] = []

        func flush() {
            if !paragraph.isEmpty {
                items.append(.paragraph(paragraph, heading: paragraphHeading, section: section))
            }
            paragraph = []
            paragraphHeading = []
        }

        func indent(of line: Line) -> CGFloat {
            guard let page = pageByIndex[line.page] else { return 0 }
            return line.rect.minX - page.range(for: line.column).lowerBound
        }
        func columnWidth(of line: Line) -> CGFloat {
            guard let page = pageByIndex[line.page] else { return 1 }
            let range = page.range(for: line.column)
            return range.upperBound - range.lowerBound
        }
        func nextUnconsumed(after position: Int) -> Line? {
            ordered[(position + 1)...].first { !consumed.contains($0.id) }
        }

        /// Font size of the abstract; some templates set it smaller than the body (IEEE),
        /// while footnotes of a similar size must still be skipped (NeurIPS).
        var abstractSize: CGFloat?
        let listMarker = #"^([•▪◦‣●]|[–—-]\s|\(?\d{1,2}[.)]\s|\([a-z]\)\s)"#
        /// Indent of the current list item's marker; continuation lines sit deeper.
        var listIndent: CGFloat?
        var skipIDs = Set<Int>()

        for position in ordered.indices where position >= start {
            let line = ordered[position]
            guard let page = pageByIndex[line.page], !skipIDs.contains(line.id) else { continue }

            if let equation = equationByFirstID[line.id] {
                flush()
                pendingHeading = []
                items.append(.equation(equation, section: section))
                continue
            }
            if consumed.contains(line.id) {
                continue
            }
            if Self.matches(line.text, #"(?i)^abstract\b"#), topSection == nil {
                topSection = "Abstract"
            }
            // Long numbered headings fill the column like body text, so also accept a numbered line
            // that follows a finished sentence and precedes an indented paragraph.
            let isStructuralHeading = Self.matches(line.text, #"^([IVXL]+|[A-Z]|\d+(\.\d+)*)\.?\s+[A-Z]"#)
                && line.text.split(separator: " ").count <= 12
                && !Self.matches(line.text, #"[.,;]$"#)
                && (paragraph.last.map { Self.matches($0.text, #"[.?!:]$"#) } ?? true)
                && nextUnconsumed(after: position).map { indent(of: $0) >= 4 && indent(of: $0) <= 24 } == true
            if isHeading(line, in: page) || isStructuralHeading {
                flush()
                listIndent = nil
                if isReferencesHeading(line.text) {
                    stopPosition = position
                    break
                }
                var title = line.text
                pendingHeading = [line]
                // A heading wrapped onto a short second line ("… From Transformers to" / "State-Space Models").
                if let next = nextUnconsumed(after: position),
                   next.page == line.page, next.column == line.column,
                   line.rect.minY - next.rect.maxY < bodySize * 0.6,
                   next.rect.width < columnWidth(of: next) * 0.5,
                   !Self.matches(next.text, #"[.?!]$"#),
                   !Self.matches(next.text, #"^([IVXL]+|[A-Z]|\d+(\.\d+)*)\.\s"#),
                   let following = nextUnconsumed(after: positionByID[next.id] ?? position),
                   indent(of: following) >= 4 {
                    title += " " + next.text
                    skipIDs.insert(next.id)
                    pendingHeading.append(next)
                }
                if isTopLevelHeading(title, previousSubsection: subSection?.first) {
                    topSection = title
                    subSection = nil
                } else {
                    subSection = title
                }
                continue
            }
            if topSection == "Abstract", abstractSize == nil, line.fontSize > 0 {
                abstractSize = line.fontSize
            }
            guard isProseSize(line) else { continue }
            if line.fontSize > 0, line.fontSize < bodySize * 0.95 {
                guard topSection == "Abstract", let abstractSize, abs(line.fontSize - abstractSize) < 0.3 else {
                    continue
                }
            }

            let lineIndent = indent(of: line)
            let startsListItem = Self.matches(line.text, listMarker)
            if let previous = paragraph.last {
                let previousIndent = indent(of: previous)
                let afterDropCap = previous.rect.height > bodySize * 1.8
                let previousEndedShort = previous.rect.width < columnWidth(of: previous) * 0.85
                    && Self.matches(previous.text, #"[.?!:]$"#)
                // A first-line indent marks a new paragraph unless every line shares it (hanging list text).
                var breaks = lineIndent >= 4 && lineIndent <= 24 && !afterDropCap
                    && (abs(lineIndent - previousIndent) > 2 || previousEndedShort)
                if let listIndent {
                    breaks = startsListItem || lineIndent <= listIndent + 2
                } else if startsListItem {
                    breaks = true
                }
                if previous.page == line.page, previous.column == line.column {
                    let gap = previous.rect.minY - line.rect.maxY
                    if gap > bodySize * 0.9, breaks || Self.matches(previous.text, #"[.?!:]$"#) {
                        breaks = true
                    }
                }
                if previous.fontSize > 0, line.fontSize > 0, abs(previous.fontSize - line.fontSize) > 0.6 {
                    breaks = true
                }
                if breaks {
                    flush()
                }
            }
            if paragraph.isEmpty {
                listIndent = startsListItem ? lineIndent : nil
                paragraphHeading = pendingHeading
                pendingHeading = []
            }
            paragraph.append(line)
        }
        flush()

        let blocks = assemble(items: items, visuals: visuals.filter { $0.position < stopPosition })
        let startLine = ordered.indices.contains(start) ? ordered[start] : nil
        return (titleBlock(above: startLine).map { [.title($0)] } ?? []) + blocks
    }

    /// The title and author block: from the largest text on the first page down to the abstract.
    /// Notices printed above the title are left out.
    private func titleBlock(above startLine: Line?) -> TitleBlock? {
        guard let startLine, startLine.page <= 1,
              let page = pages.first(where: { $0.index == startLine.page })
        else {
            return nil
        }
        let above = page.lines.filter { $0.rect.minY > startLine.rect.maxY }
        guard let largest = above.map(\.fontSize).max(), largest >= bodySize * 1.3 else { return nil }
        let titleLines = above
            .filter { abs($0.fontSize - largest) < 0.6 }
            .sorted { $0.rect.maxY > $1.rect.maxY }
        let titleTop = titleLines.map(\.rect.maxY).max()!
        // Body text level with the abstract (e.g. the other column) marks the bottom.
        let bodyTop = page.lines
            .filter { $0.rect.minY <= startLine.rect.maxY }
            .map(\.rect.maxY).max() ?? startLine.rect.maxY
        // End just below the last author line rather than at the abstract.
        let authorBottom = page.lines
            .filter { $0.rect.minY > bodyTop && $0.rect.maxY <= titleTop }
            .map(\.rect.minY).min() ?? bodyTop
        let bottom = max(bodyTop + 3, authorBottom - 6)
        let span = page.range(for: .span)
        let left = min(span.lowerBound, titleLines.map(\.rect.minX).min()!) - 4
        let right = max(span.upperBound, titleLines.map(\.rect.maxX).max()!) + 4
        let rect = CGRect(x: left, y: bottom, width: right - left, height: titleTop + 4 - bottom)
        guard rect.height >= 24 else { return nil }
        return TitleBlock(
            pageNumber: page.index + 1,
            title: joinLines(titleLines),
            region: PDFRegion(pageIndex: page.index, rect: rect)
        )
    }

    private func assemble(items: [FlowItem], visuals: [VisualElement]) -> [PaperBlock] {
        // Expand paragraphs into card-sized chunks first so context and placement use final cards.
        struct Snippet {
            let lines: [Line]
            let text: String
        }
        enum Card {
            /// `shownLines` adds the section heading to the first card's image.
            case text(lines: [Line], shownLines: [Line], text: String, section: String?)
            case equation(Equation, section: String?, leadIn: Snippet?, followUp: Snippet?)
        }
        var cards: [Card] = []
        for item in items {
            switch item {
            case .paragraph(let lines, let heading, let section):
                for (chunkIndex, chunk) in chunks(of: lines).enumerated() {
                    let text = joinLines(chunk)
                    let shown = chunkIndex == 0 ? heading + chunk : chunk
                    let isKeywords = Self.matches(text, #"(?i)^(index terms|keywords)\b"#)
                    if isKeywords {
                        continue
                    }
                    // Fold the sentence fragment around an equation into its card:
                    // "… the hidden state evolves as" [equation] "where A is …".
                    if case .equation(let equation, let eqSection, let leadIn, nil)? = cards.last,
                       text.count <= 400, text.first?.isLowercase == true {
                        cards[cards.count - 1] = .equation(
                            equation, section: eqSection, leadIn: leadIn,
                            followUp: Snippet(lines: chunk, text: text)
                        )
                        continue
                    }
                    let isFragment = text.count < 50 && !Self.matches(text, #"[.?!:]$"#)
                    if !isFragment {
                        cards.append(.text(lines: chunk, shownLines: shown, text: text, section: section))
                    }
                }
            case .equation(let equation, let section):
                var leadIn: Snippet?
                if case .text(_, let shown, let text, _)? = cards.last, text.count <= 220, !text.hasSuffix(".") {
                    leadIn = Snippet(lines: shown, text: text)
                    cards.removeLast()
                }
                cards.append(.equation(equation, section: section, leadIn: leadIn, followUp: nil))
            }
        }

        func textOf(_ index: Int) -> String? {
            guard cards.indices.contains(index), case .text(_, _, let text, _) = cards[index] else { return nil }
            return text
        }
        func position(of card: Card) -> Int {
            switch card {
            case .text(let lines, _, _, _): positionByID[lines[0].id] ?? 0
            case .equation(let equation, _, _, _): positionByID[equation.lines[0].id] ?? 0
            }
        }

        // Show each figure/table right after the paragraph that first mentions it.
        var visualsAfter: [Int: [VisualElement]] = [:]
        var mentionContext: [String: String] = [:]
        for visual in visuals.sorted(by: { $0.position < $1.position }) {
            let mention = cards.indices.first { index in
                textOf(index).map { Self.matches($0, visual.mentionPattern) } ?? false
            }
            let anchor = mention ?? (cards.lastIndex { position(of: $0) < visual.position } ?? -1)
            if let mention, let text = textOf(mention) {
                mentionContext[visual.key] = text
            }
            visualsAfter[anchor, default: []].append(visual)
        }

        var blocks: [PaperBlock] = []
        var lastSection: String?

        func appendVisuals(after index: Int) {
            for visual in visualsAfter[index] ?? [] {
                let pageNumber = visual.region.pageIndex + 1
                switch visual.kind {
                case .figure, .algorithm:
                    blocks.append(.figure(FigureBlock(
                        pageNumber: pageNumber, section: lastSection, isAlgorithm: visual.kind == .algorithm,
                        caption: visual.caption, content: visual.content,
                        context: mentionContext[visual.key], region: visual.region
                    )))
                case .table:
                    blocks.append(.table(TableBlock(
                        pageNumber: pageNumber, section: lastSection, caption: visual.caption,
                        context: mentionContext[visual.key], region: visual.region
                    )))
                }
            }
        }

        appendVisuals(after: -1)
        for (index, card) in cards.enumerated() {
            switch card {
            case .text(let lines, let shown, let text, let section):
                lastSection = section
                let previous = (index > 0 ? textOf(index - 1) : nil).map { String($0.suffix(600)) }
                blocks.append(.text(TextBlock(
                    pageNumber: lines[0].page + 1,
                    section: section,
                    original: text,
                    context: previous,
                    regions: region(for: shown)
                )))
            case .equation(let equation, let section, let leadIn, let followUp):
                lastSection = section
                let before = leadIn?.text ?? textOf(index - 1).map { String($0.suffix(300)) } ?? ""
                let after = followUp?.text ?? textOf(index + 1).map { String($0.prefix(300)) } ?? ""
                let isNumber: (Line) -> Bool = { Self.matches($0.text, #"^\(\d{1,3}[a-z]?\)$"#) }
                let equationText = (equation.lines.filter { !isNumber($0) } + equation.lines.filter(isNumber))
                    .map(\.text).joined(separator: " ")
                blocks.append(.equation(EquationBlock(
                    pageNumber: equation.region.pageIndex + 1,
                    section: section,
                    extractedEquation: equationText,
                    leadIn: leadIn?.text,
                    followUp: followUp?.text,
                    surroundingText: [before, after].filter { !$0.isEmpty }.joined(separator: " … "),
                    regions: (leadIn.map { region(for: $0.lines) } ?? [])
                        + [equation.region]
                        + (followUp.map { region(for: $0.lines) } ?? [])
                )))
            }
            appendVisuals(after: index)
        }
        return blocks
    }

    // MARK: Regex Helpers

    static func lowercaseRatio(_ text: String) -> Double {
        let letters = text.filter(\.isLetter)
        guard !letters.isEmpty else { return 0 }
        return Double(letters.filter(\.isLowercase).count) / Double(letters.count)
    }

    static func normalizeWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        text.range(of: pattern, options: .regularExpression).map { String(text[$0]) }
    }

    static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[range])
    }

    static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}

nonisolated private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
