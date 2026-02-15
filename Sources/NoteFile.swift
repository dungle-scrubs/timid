import Foundation

/// Represents a markdown note file on disk.
/// Content is loaded on-demand via `loadContent()` to avoid reading every file at startup.
struct NoteFile: Identifiable {
    let id = UUID()
    let url: URL
    let modifiedAt: Date
    let relativePath: String

    var name: String {
        url.deletingPathExtension().lastPathComponent
    }

    var searchableName: String {
        name.lowercased()
    }

    /// Reads the file content from disk.
    /// @returns The UTF-8 string content of the file.
    /// @throws If the file cannot be read.
    func loadContent() throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}
