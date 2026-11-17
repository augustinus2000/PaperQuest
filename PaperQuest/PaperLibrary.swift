import Foundation
import Observation
import OSLog

struct SavedPaper: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    let pageCount: Int
    let addedAt: Date
    var currentIndex = 0
    var cardCount = 0
    var isCompleted = false
    var analysisVersion: Int?
    /// When the paper was last opened or advanced; `nil` until first read.
    var lastOpenedAt: Date?

    /// Share of cards read, 0...1.
    var progress: Double {
        guard cardCount > 0 else { return 0 }
        return isCompleted ? 1 : Double(currentIndex + 1) / Double(cardCount)
    }
}

@MainActor
@Observable
final class PaperLibrary {
    private(set) var papers: [SavedPaper] = []
    private(set) var loadError: String?
    private let directory: URL

    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("PaperLibrary", isDirectory: true)) {
        self.directory = directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let indexURL = directory.appendingPathComponent("library.json")
            if FileManager.default.fileExists(atPath: indexURL.path) {
                papers = try JSONDecoder().decode([SavedPaper].self, from: Data(contentsOf: indexURL))
            }
        } catch {
            // Never overwrite an unreadable library with an empty one.
            loadError = error.localizedDescription
        }
    }

    func importPaper(from source: URL) async throws -> SavedPaper {
        let id = UUID()
        let destination = pdfURL(for: id)
        do {
            let hasAccess = source.startAccessingSecurityScopedResource()
            defer {
                if hasAccess { source.stopAccessingSecurityScopedResource() }
            }
            try FileManager.default.copyItem(at: source, to: destination)
        }
        do {
            let pageCount = try await Self.validatedPageCount(of: destination)
            let paper = SavedPaper(
                id: id,
                title: source.deletingPathExtension().lastPathComponent,
                pageCount: pageCount,
                addedAt: .now,
                analysisVersion: Self.analysisVersion
            )
            try commit([paper] + papers)
            return paper
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func openPaper(_ paper: SavedPaper) async throws -> [PaperBlock] {
        let blocks = try await Self.analyzePaper(at: pdfURL(for: paper.id))
        guard let position = papers.firstIndex(where: { $0.id == paper.id }) else {
            return blocks
        }
        var updated = papers
        if updated[position].analysisVersion != Self.analysisVersion {
            // Cards from an older analyzer don't map onto the new ones, so restart the paper.
            updated[position].currentIndex = 0
            updated[position].isCompleted = false
            updated[position].analysisVersion = Self.analysisVersion
        }
        updated[position].currentIndex = min(
            max(0, updated[position].currentIndex), max(0, blocks.count - 1)
        )
        updated[position].cardCount = blocks.count
        updated[position].lastOpenedAt = .now
        try commit(updated)
        return blocks
    }

    func saveProgress(for id: UUID, index: Int, cardCount: Int, completed: Bool) throws {
        guard let position = papers.firstIndex(where: { $0.id == id }) else { return }
        var updated = papers
        updated[position].currentIndex = min(max(0, index), max(0, cardCount - 1))
        updated[position].cardCount = cardCount
        updated[position].isCompleted = completed
        updated[position].lastOpenedAt = .now
        try commit(updated)
    }

    /// Most recently read first; papers never opened follow by date added.
    var recentPapers: [SavedPaper] {
        papers.sorted { ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt) }
    }

    /// The paper to resume: the most recently read one that isn't finished.
    var paperToResume: SavedPaper? {
        recentPapers.first { $0.lastOpenedAt != nil && !$0.isCompleted && $0.cardCount > 0 }
    }

    func renamePaper(_ id: UUID, to title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let position = papers.firstIndex(where: { $0.id == id }) else { return }
        var updated = papers
        updated[position].title = trimmed
        try commit(updated)
    }

    /// Removes the paper with its PDF and saved translations/explanations.
    func deletePaper(_ id: UUID) throws {
        guard papers.contains(where: { $0.id == id }) else { return }
        // Update the index first so a listed paper never points at a deleted PDF.
        try commit(papers.filter { $0.id != id })
        let pdf = pdfURL(for: id)
        try? FileManager.default.removeItem(at: pdf)
        try? FileManager.default.removeItem(
            at: pdf.deletingPathExtension().appendingPathExtension("assistance")
        )
    }

    func pdfURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("pdf")
    }

    // MARK: Background PDF Work

    /// Bump when card boundaries change; saved positions from other versions restart at the first card.
    private static let analysisVersion = 8

    /// Parses the PDF off the main actor so large papers don't freeze the UI.
    @concurrent
    private nonisolated static func validatedPageCount(of url: URL) async throws -> Int {
        try PDFImportService.importPaper(from: url).pageCount
    }

    /// Parses and analyzes off the main actor.
    @concurrent
    private nonisolated static func analyzePaper(at url: URL) async throws -> [PaperBlock] {
        let (imported, importTime) = try PerformanceLog.measure("PDF import") {
            try PDFImportService.importPaper(from: url)
        }
        let (blocks, analysisTime) = PerformanceLog.measure("Layout analysis") {
            PaperAnalyzer.analyze(paper: imported)
        }
        PerformanceLog.logger.info("""
            open paper: pages=\(imported.pageCount) cards=\(blocks.count) \
            import=\(PerformanceLog.milliseconds(importTime), privacy: .public) \
            analysis=\(PerformanceLog.milliseconds(analysisTime), privacy: .public)
            """)
        return blocks
    }

    private func commit(_ updated: [SavedPaper]) throws {
        guard loadError == nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let data = try JSONEncoder().encode(updated)
        try data.write(to: directory.appendingPathComponent("library.json"), options: .atomic)
        papers = updated
    }
}
