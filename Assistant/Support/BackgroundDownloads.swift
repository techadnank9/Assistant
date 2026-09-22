import Foundation

/// Downloads Hugging Face model repos with a background URLSession, so a 1 GB model keeps
/// downloading when the app is in the background or has been closed. iOS finishes the transfers
/// on its own and relaunches the app briefly to hand them over (see AppDelegate).
///
/// Files land in Application Support/Models/<org>--<name>/, mirroring the repo layout, which is
/// exactly what the MLX loaders take as a local model directory.
final class BackgroundDownloads: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = BackgroundDownloads()
    static let sessionID = "ai.assistantagent.call.models"

    /// Set by the app delegate when iOS relaunches the app to deliver finished downloads.
    var backgroundCompletion: (() -> Void)?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.isDiscretionary = false            // start now, not when iOS finds it convenient
        config.sessionSendsLaunchEvents = true    // relaunch the app when downloads finish
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private let lock = NSLock()
    private var jobs: [String: Job] = [:]      // repo → in-progress download

    private final class Job {
        var totalBytes: Int64 = 0
        var doneBytes: [String: Int64] = [:]  // path → bytes on disk or written so far
        var remaining: Set<String> = []
        var waiters: [CheckedContinuation<Void, Error>] = []
        var progress: (@Sendable (Double) -> Void)?
    }

    private struct RemoteFile: Decodable {
        let type: String
        let path: String
        let size: Int64?
    }

    // MARK: Locations

    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var url = base.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true        // re-downloadable; keep it out of iCloud backups
        try? url.setResourceValues(values)
        return url
    }

    static func directory(for repo: String) -> URL {
        root.appendingPathComponent(repo.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
    }

    /// True when every one of `paths` is already on disk (files only appear once fully downloaded).
    static func hasFiles(_ repo: String, _ paths: [String]) -> Bool {
        let dir = directory(for: repo)
        return paths.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    static func delete(_ repo: String) {
        try? FileManager.default.removeItem(at: directory(for: repo))
    }

    // MARK: Downloading

    /// Recreates the session so iOS can deliver transfers that finished while the app was closed.
    func reconnect() {
        _ = session
    }

    /// Makes sure every file of `repo` accepted by `include` is on disk, downloading what's missing
    /// in the background. Returns the local directory.
    func ensure(
        repo: String,
        include: @escaping @Sendable (String) -> Bool,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let files = try await listFiles(repo).filter { $0.type == "file" && include($0.path) }
        guard !files.isEmpty else { throw DownloadError.emptyRepo(repo) }
        let dir = Self.directory(for: repo)

        let job = Job()
        job.progress = progress
        for file in files {
            let size = file.size ?? 0
            job.totalBytes += size
            let local = dir.appendingPathComponent(file.path)
            let onDisk = (try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
            if onDisk == size, size > 0 || FileManager.default.fileExists(atPath: local.path) {
                job.doneBytes[file.path] = size
            } else {
                job.remaining.insert(file.path)
                job.doneBytes[file.path] = 0
            }
        }

        if !job.remaining.isEmpty {
            // Transfers may already be running from a previous launch; don't start them twice.
            let running = Set(await session.allTasks.compactMap(\.taskDescription))
            let needed = job.remaining
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    if let existing = jobs[repo] {
                        existing.waiters.append(continuation)
                        return
                    }
                    job.waiters.append(continuation)
                    jobs[repo] = job
                }
                Log.info(.model, "Background download of \(repo): \(needed.count) files, \(job.totalBytes / 1_000_000) MB")
                report(repo)
                for path in needed where !running.contains(Self.describe(repo, path)) {
                    let task = session.downloadTask(with: Self.remoteURL(repo, path))
                    task.taskDescription = Self.describe(repo, path)
                    task.resume()
                }
            }
        }

        progress(1)
        Log.info(.model, "Downloaded \(repo)")
        return dir
    }

    private func listFiles(_ repo: String) async throws -> [RemoteFile] {
        let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main?recursive=true")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DownloadError.listFailed(repo) }
        return try JSONDecoder().decode([RemoteFile].self, from: data)
    }

    private static func remoteURL(_ repo: String, _ path: String) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(path)")!
    }

    private static func describe(_ repo: String, _ path: String) -> String { "\(repo)|\(path)" }

    private static func parse(_ description: String?) -> (repo: String, path: String)? {
        guard let parts = description?.split(separator: "|", maxSplits: 1), parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    private func report(_ repo: String) {
        let (fraction, handler): (Double, (@Sendable (Double) -> Void)?) = lock.withLock {
            guard let job = jobs[repo], job.totalBytes > 0 else { return (0, nil) }
            let done = job.doneBytes.values.reduce(0, +)
            return (min(1, Double(done) / Double(job.totalBytes)), job.progress)
        }
        handler?(fraction)
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let (repo, path) = Self.parse(downloadTask.taskDescription) else { return }
        lock.withLock { jobs[repo]?.doneBytes[path] = totalBytesWritten }
        report(repo)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let (repo, path) = Self.parse(downloadTask.taskDescription) else { return }
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
            fail(repo, DownloadError.http(status, path))
            return
        }
        // The temporary file disappears when this method returns, so move it now.
        let destination = Self.directory(for: repo).appendingPathComponent(path)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            fail(repo, error)
            return
        }
        let finished: [CheckedContinuation<Void, Error>] = lock.withLock {
            guard let job = jobs[repo] else { return [] }
            job.remaining.remove(path)
            job.doneBytes[path] = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            guard job.remaining.isEmpty else { return [] }
            jobs[repo] = nil
            return job.waiters
        }
        report(repo)
        finished.forEach { $0.resume() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let (repo, path) = Self.parse(task.taskDescription) else { return }
        Log.error(.model, "Download of \(path) failed: \(error.localizedDescription)")
        fail(repo, error)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [self] in
            backgroundCompletion?()
            backgroundCompletion = nil
        }
    }

    private func fail(_ repo: String, _ error: Error) {
        let waiters: [CheckedContinuation<Void, Error>] = lock.withLock {
            let waiters = jobs[repo]?.waiters ?? []
            jobs[repo] = nil
            return waiters
        }
        // Stop the rest of this repo's transfers; a retry starts cleanly from what's on disk.
        session.getAllTasks { tasks in
            for task in tasks where Self.parse(task.taskDescription)?.repo == repo { task.cancel() }
        }
        waiters.forEach { $0.resume(throwing: error) }
    }

    enum DownloadError: LocalizedError {
        case listFailed(String), emptyRepo(String), http(Int, String)

        var errorDescription: String? {
            switch self {
            case .listFailed(let repo): "Couldn't reach Hugging Face to list \(repo). Check the connection and try again."
            case .emptyRepo(let repo): "\(repo) has no model files."
            case .http(let code, let path): "Download of \(path) failed (HTTP \(code))."
            }
        }
    }
}
