import Foundation
import HuggingFace

/// The model files on this iPhone: where they live, how big they are, and deleting them.
/// Downloads go to the Hugging Face cache in the app's Caches folder, one folder per model.
/// iOS may clear Caches when storage runs low; the model then downloads again when needed.
enum ModelFiles {
    struct Downloaded: Identifiable, Hashable {
        let id: String       // e.g. mlx-community/Qwen3-1.7B-4bit
        let bytes: Int64
    }

    static var root: URL { HubCache.default.cacheDirectory }

    private static func folderName(_ id: String) -> String {
        "models--" + id.replacingOccurrences(of: "/", with: "--")
    }

    private static func folders(for id: String) -> [URL] {
        [root.appendingPathComponent(folderName(id)),
         root.appendingPathComponent(".metadata").appendingPathComponent(folderName(id))]
    }

    /// Every downloaded model (background downloads and the older cache), with its size on disk.
    static func downloaded() -> [Downloaded] {
        var ids = Set<String>()
        let cached = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in cached where name.hasPrefix("models--") {
            ids.insert(String(name.dropFirst("models--".count)).replacingOccurrences(of: "--", with: "/"))
        }
        let background = (try? FileManager.default.contentsOfDirectory(atPath: BackgroundDownloads.root.path)) ?? []
        for name in background where name.contains("--") {
            ids.insert(name.replacingOccurrences(of: "--", with: "/"))
        }
        return ids.map { Downloaded(id: $0, bytes: bytes(for: $0)) }
            .filter { $0.bytes > 0 }
            .sorted { $0.id < $1.id }
    }

    static func bytes(for id: String) -> Int64 {
        size(of: folders(for: id)[0]) + size(of: BackgroundDownloads.directory(for: id))
    }

    /// Files worth downloading from a model repo (weights, config, tokenizer, voices), not docs or samples.
    static func isModelFile(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.hasPrefix("samples/") { return false }
        return [".safetensors", ".json", ".jinja", ".txt", ".model", ".tiktoken"].contains { lower.hasSuffix($0) }
    }

    /// A local folder holding the model: a background download, or an older Hugging Face cache snapshot.
    /// Files only appear once fully downloaded, so their presence means they're usable.
    static func localDirectory(for id: String, requiring paths: [String] = ["config.json", "tokenizer.json"]) -> URL? {
        if BackgroundDownloads.hasFiles(id, paths),
           let files = try? FileManager.default.contentsOfDirectory(atPath: BackgroundDownloads.directory(for: id).path),
           files.contains(where: { $0.hasSuffix(".safetensors") }) {
            return BackgroundDownloads.directory(for: id)
        }
        let snapshots = folders(for: id)[0].appendingPathComponent("snapshots")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)) ?? []
        for name in names {
            let dir = snapshots.appendingPathComponent(name)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            if files.contains("config.json"), files.contains(where: { $0.hasSuffix(".safetensors") }) { return dir }
        }
        return nil
    }

    static func delete(_ id: String) throws {
        for url in folders(for: id) where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        BackgroundDownloads.delete(id)
        Log.info(.model, "Deleted \(id) from this iPhone")
    }

    private static func size(of folder: URL) -> Int64 {
        guard let items = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.fileAllocatedSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in items {
            let values = try? url.resourceValues(forKeys: [.fileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileAllocatedSize ?? 0) }
        }
        return total
    }
}
