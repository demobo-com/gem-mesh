import Foundation

/// Resumable download of one model file from Hugging Face into `<file>.part`, with a byte-count check before it is
/// renamed into place (ModelDownloader.kt). Wi-Fi only unless `allowCellular`. The app stays open during the first
/// download; an interrupted one resumes where it stopped.
final class ModelDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var handle: FileHandle?
    private var done: Int64 = 0
    private var expected: Int64 = 0
    private var lastReport = Date.distantPast
    private var progress: ((Int64, Int64) -> Void)?
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func fetch(_ url: URL, to dest: URL, expectedBytes: Int64, allowCellular: Bool,
               onProgress: @escaping (Int64, Int64) -> Void) async throws {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value, size == expectedBytes { return }
        let part = dest.appendingPathExtension("part")
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        let have = (try? fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
        if have == expectedBytes {
            // Finished earlier but the app stopped before the rename: asking for more would only get HTTP 416.
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: part, to: dest)
            onProgress(expectedBytes, expectedBytes)
            return
        }
        if have > expectedBytes { try? fm.removeItem(at: part); fm.createFile(atPath: part.path, contents: nil) }
        let start = have > expectedBytes ? 0 : have

        var req = URLRequest(url: url)
        if start > 0 { req.setValue("bytes=\(start)-", forHTTPHeaderField: "Range") }
        req.allowsExpensiveNetworkAccess = allowCellular
        req.allowsCellularAccess = allowCellular
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        session = s
        expected = expectedBytes
        progress = onProgress
        handle = try FileHandle(forWritingTo: part)
        done = start

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                continuation = c
                let t = s.dataTask(with: req)
                task = t
                t.resume()
            }
        } onCancel: {
            self.task?.cancel()
        }
        s.finishTasksAndInvalidate()

        let size = (try? fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
        if size != expectedBytes { throw Failure(message: "download: got \(size) bytes, expected \(expectedBytes)") }
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: part, to: dest)
        onProgress(expectedBytes, expectedBytes)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            completionHandler(.cancel)
            finish(Failure(message: "download: HTTP \(status)"))
            return
        }
        if status == 200 {
            // The server ignored the range: start the file again.
            try? handle?.truncate(atOffset: 0)
            done = 0
        } else {
            _ = try? handle?.seekToEnd()
        }
        progress?(done, expected) // connected; shows where a resumed download starts
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        try? handle?.write(contentsOf: data)
        done += Int64(data.count)
        if Date().timeIntervalSince(lastReport) >= 1 {
            lastReport = Date()
            progress?(done, expected)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error)
    }

    private func finish(_ error: Error?) {
        try? handle?.close()
        handle = nil
        guard let c = continuation else { return }
        continuation = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }
}
