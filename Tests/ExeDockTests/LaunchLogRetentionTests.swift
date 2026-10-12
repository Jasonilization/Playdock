import Foundation
import Testing
@testable import ExeDock

/// Retention over the per-run launch logs: keeps the newest files, sweeps the rest, and never
/// touches the app's own append-only diagnostics history.
@Suite("LaunchLogRetention")
struct LaunchLogRetentionTests {
    @Test func keepsNewestLogsAndSparesDiagnostics() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-retention-tests-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fm = FileManager.default

        func write(_ name: String, ageDays: Double) {
            let path = (dir as NSString).appendingPathComponent(name)
            fm.createFile(atPath: path, contents: nil)
            try? fm.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -ageDays * 86_400)],
                ofItemAtPath: path)
        }

        // Ten per-run logs aged 10..1 days, one fresh, and a deliberately old diagnostics.log.
        for day in 0..<10 { write("game-\(day).log", ageDays: Double(10 - day)) }
        write("game-fresh.log", ageDays: 0)
        write("diagnostics.log", ageDays: 30)

        LaunchLogRetention.prune(keeping: 3, in: dir)

        let remaining = Set(try fm.contentsOfDirectory(atPath: dir))
        #expect(remaining.contains("diagnostics.log"))  // never swept, regardless of age
        #expect(remaining.contains("game-fresh.log"))
        #expect(remaining.contains("game-9.log"))
        #expect(remaining.contains("game-8.log"))        // the newest three .log files
        #expect(!remaining.contains("game-7.log"))
        #expect(!remaining.contains("game-0.log"))
        #expect(remaining.count == 4)                     // 3 kept + diagnostics
    }

    @Test func smallDirectoryIsLeftUntouched() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-retention-tests-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fm = FileManager.default
        for day in 0..<3 {
            let path = (dir as NSString).appendingPathComponent("game-\(day).log")
            fm.createFile(atPath: path, contents: nil)
        }

        LaunchLogRetention.prune(keeping: 300, in: dir)

        #expect(try fm.contentsOfDirectory(atPath: dir).count == 3)
    }
}
