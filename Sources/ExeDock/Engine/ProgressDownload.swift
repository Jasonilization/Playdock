import Foundation

/// Downloads a file and reports how many bytes have landed. `expected` is negative when the
/// server does not say how big the file is.
enum ProgressDownload {
    static func save(from url: URL, to destination: String, onBytes: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let box = DownloadBox(destination: destination, onBytes: onBytes)
        let session = URLSession(configuration: .default, delegate: box, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await box.start(session: session, url: url)
    }
}

private final class DownloadBox: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: String
    let onBytes: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false

    init(destination: String, onBytes: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.onBytes = onBytes
    }

    func start(session: URLSession, url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            let task = session.downloadTask(with: url)
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onBytes(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                finish(.failure(SteamInstallError.downloadFailed("unexpected server response")))
                return
            }
            let dest = URL(fileURLWithPath: destination)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, let continuation else { return }
        finished = true
        self.continuation = nil
        continuation.resume(with: result)
    }
}
