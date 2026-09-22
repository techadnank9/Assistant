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

    /// Every model folder in the cache, with its size on disk.
    static func downloaded() -> [Downloaded] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names
            .filter { $0.hasPrefix("models--") }
            .map { name in
                let id = String(name.dropFirst("models--".count)).replacingOccurrences(of: "--", with: "/")
                return Downloaded(id: id, bytes: size(of: root.appendingPathComponent(name)))
            }
            .filter { $0.bytes > 0 }
            .sorted { $0.id < $1.id }
    }

    static func bytes(for id: String) -> Int64 {
        size(of: folders(for: id)[0])
    }

    static func delete(_ id: String) throws {
        for url in folders(for: id) where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
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
