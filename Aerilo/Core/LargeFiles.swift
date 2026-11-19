import Foundation

/// A large file in one of the folders people fill up: Downloads, Documents, Desktop, Movies.
struct BigFile: Identifiable, Hashable {
    let url: URL
    let bytes: Int64
    /// When it was last opened, if the system knows.
    let lastOpened: Date?
    var id: URL { url }
    var folder: String { url.deletingLastPathComponent().lastPathComponent }
}

/// Finds large files for the user to look at. It deletes nothing: the only action offered is
/// "Move to Trash", one file at a time, which the user can undo from the Trash.
enum LargeFiles {
    static let minimum: Int64 = 200_000_000

    static func scan(home: URL) -> [BigFile] {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey, .contentAccessDateKey]
        var found: [BigFile] = []
        for folder in ["Downloads", "Documents", "Desktop", "Movies"] {
            let root = home.appendingPathComponent(folder)
            // Not inside apps, photo libraries or other bundles: those are one thing to the user, not loose files.
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
            for case let file as URL in walker {
                guard let v = try? file.resourceValues(forKeys: keys), v.isRegularFile == true,
                      let size = v.totalFileAllocatedSize, Int64(size) >= minimum else { continue }
                found.append(BigFile(url: file, bytes: Int64(size), lastOpened: v.contentAccessDate))
            }
        }
        return Array(found.sorted { $0.bytes > $1.bytes }.prefix(40))
    }
}
