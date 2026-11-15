import Foundation

/// A single append-only log for things that fail silently by design elsewhere (a card just falls
/// back to a placeholder icon rather than showing an error) - so "is this actually working" has a
/// real answer instead of just "well, it looks fine so far." Lives alongside the per-launch wine
/// logs in `ExeRunner.logsDir`, so one "Open Logs Folder" button in Settings surfaces everything.
enum DiagnosticsLog {
    static var path: String { (ExeRunner.logsDir as NSString).appendingPathComponent("diagnostics.log") }

    static func log(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: ExeRunner.logsDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: path), let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            fm.createFile(atPath: path, contents: data)
        }
    }
}
