import Foundation

/// Downloads a file straight onto the target drive (no copy through the
/// Mac's own disk), resuming a partial file when the server allows it.
public final class FileDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public typealias Progress = @Sendable (_ received: Int64, _ total: Int64) -> Void

    private let destination: URL
    private let expectedSize: Int64
    private let progress: Progress
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var total: Int64 = 0
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var lastReport = Date.distantPast

    public init(destination: URL, expectedSize: Int64, progress: @escaping Progress) {
        self.destination = destination
        self.expectedSize = expectedSize
        self.progress = progress
    }

    public static func download(_ url: URL, to destination: URL, expectedSize: Int64, progress: @escaping Progress) async throws {
        let d = FileDownloader(destination: destination, expectedSize: expectedSize, progress: progress)
        try await d.start(url)
    }

    public func cancel() { task?.cancel() }

    func start(_ url: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var existing: Int64 = 0
        if let attrs = try? fm.attributesOfItem(atPath: destination.path), let s = attrs[.size] as? NSNumber {
            existing = s.int64Value
        }
        if expectedSize > 0 && existing == expectedSize {
            progress(existing, existing)
            return   // already complete
        }
        if existing > expectedSize && expectedSize > 0 { try? fm.removeItem(at: destination); existing = 0 }
        if !fm.fileExists(atPath: destination.path) { fm.createFile(atPath: destination.path, contents: nil) }

        var req = URLRequest(url: url)
        if existing > 0 { req.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
        received = existing

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 60 * 60 * 6
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        self.session = session
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                self.continuation = c
                let t = session.dataTask(with: req)
                self.task = t
                t.resume()
            }
        } onCancel: {
            self.task?.cancel()
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        do {
            let h = try FileHandle(forWritingTo: destination)
            if http?.statusCode == 206 {
                try h.seekToEnd()
            } else {
                // Server ignored the Range header: start over.
                try h.truncate(atOffset: 0)
                received = 0
            }
            handle = h
        } catch {
            completionHandler(.cancel)
            finish(error)
            return
        }
        guard let code = http?.statusCode, code == 200 || code == 206 else {
            completionHandler(.cancel)
            finish(DownloadError.http(http?.statusCode ?? 0))
            return
        }
        total = received + max(response.expectedContentLength, 0)
        if expectedSize > 0 { total = expectedSize }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do { try handle?.write(contentsOf: data) } catch {
            dataTask.cancel()
            finish(error)
            return
        }
        received += Int64(data.count)
        if Date().timeIntervalSince(lastReport) > 0.25 {
            lastReport = Date()
            progress(received, total)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        progress(received, total)
        if error == nil, expectedSize > 0, received != expectedSize {
            finish(DownloadError.incomplete(received, expectedSize))
        } else {
            finish(error)
        }
    }

    private func finish(_ error: Error?) {
        try? handle?.close()
        handle = nil
        session?.finishTasksAndInvalidate()
        session = nil
        guard let c = continuation else { return }
        continuation = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }
}

public enum DownloadError: LocalizedError {
    case http(Int)
    case incomplete(Int64, Int64)
    case noSpace(need: Int64, have: Int64)
    public var errorDescription: String? {
        switch self {
        case .http(let c): return "Apple's server answered HTTP \(c)."
        case .incomplete(let got, let want): return "Download stopped early (\(formatBytes(got)) of \(formatBytes(want)))."
        case .noSpace(let need, let have): return "Not enough space on the drive: needs about \(formatBytes(need)), has \(formatBytes(have))."
        }
    }
}

/// Downloads a catalog installer to the drive and turns it into an
/// "Install macOS ….app" in Installers/.
public enum InstallerBuilder {
    /// Everything that needs no admin rights: downloads the product's packages
    /// and .dist file into the drive's staging folder.
    public static func stage(_ product: CatalogInstaller, layout: DriveLayout,
                             progress: @escaping @Sendable (String, Double) -> Void) async throws -> URL {
        let dir = layout.stagingDir.appendingPathComponent(product.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // The packages, then expanding them, take roughly twice their size.
        let already = (product.packages.map { dir.appendingPathComponent($0.filename) })
            .compactMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber }
            .reduce(Int64(0)) { $0 + $1.int64Value }
        let need = product.totalSize * 2 - already + 500_000_000
        let have = Disks.freeSpace(at: layout.root)
        if have > 0 && have < need { throw DownloadError.noSpace(need: need, have: have) }

        let (distData, _) = try await URLSession.shared.data(from: product.distributionURL)
        let distURL = dir.appendingPathComponent(product.distributionURL.lastPathComponent)
        try distData.write(to: distURL)

        let total = max(product.totalSize, 1)
        var done: Int64 = 0
        for pkg in product.packages {
            try Task.checkCancellation()
            let base = done
            try await FileDownloader.download(pkg.url, to: dir.appendingPathComponent(pkg.filename), expectedSize: pkg.size) { got, _ in
                let pct = Double(base + got) / Double(total)
                progress("Downloading \(pkg.filename) — \(formatBytes(base + got)) of \(formatBytes(total))", pct)
            }
            done += pkg.size
        }
        return distURL
    }
}
