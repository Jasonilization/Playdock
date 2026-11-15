import Foundation

/// Live setup status. Engine copy, unpack, and bottle init report here from background work.
/// The setup screen reads it, and a fresh-install machine also writes the latest line to
/// `setup-status.txt` so the step can be read from outside the window.
enum SetupActivity {
    enum Event: Sendable {
        case phase(String)
        case tick(String, Double?)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (Event) -> Void)?

    static func bind(_ handler: @escaping @Sendable (Event) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    /// A step that just started. Shown once in the log.
    static func phase(_ message: String) {
        emit(.phase(message))
        writeStatus(message)
    }

    /// The same step, with a newer measurement. Replaces the detail line. Does not grow the log.
    static func tick(_ message: String, fraction: Double?) {
        emit(.tick(message, fraction))
        writeStatus(message)
    }

    static func byteLabel(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        if mb >= 10 { return String(format: "%.0f MB", mb) }
        return String(format: "%.1f MB", mb)
    }

    private static func emit(_ event: Event) {
        lock.lock()
        let handler = handler
        lock.unlock()
        handler?(event)
    }

    private static func writeStatus(_ message: String) {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["PLAYDOCK_SUPPORT_DIR"] ?? env["EXEDOCK_SUPPORT_DIR"], !root.isEmpty else { return }
        let path = (root as NSString).appendingPathComponent("setup-status.txt")
        try? message.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
