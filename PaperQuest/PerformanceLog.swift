//
//  PerformanceLog.swift
//  PaperQuest
//

import Foundation
import OSLog

/// Timing for the heavy steps (PDF analysis, region rendering).
/// Messages appear in the Xcode console; signposts show up as intervals in Instruments.
nonisolated enum PerformanceLog {
    static let logger = Logger(subsystem: "PaperQuest", category: "Performance")
    static let signposter = OSSignposter(logger: logger)

    /// Runs `work`, logging how long it took under `label`.
    static func measure<T>(_ label: StaticString, _ work: () throws -> T) rethrows -> (T, Duration) {
        let interval = signposter.beginInterval(label)
        let clock = ContinuousClock()
        let start = clock.now
        defer { signposter.endInterval(label, interval) }
        let result = try work()
        return (result, clock.now - start)
    }

    static func milliseconds(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        return String(format: "%.1fms", Double(seconds) * 1_000 + Double(attoseconds) / 1e15)
    }
}
