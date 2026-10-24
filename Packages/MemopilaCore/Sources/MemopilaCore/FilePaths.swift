import Foundation

/// Path normalization for file references (PLAN §3.3.1): one algorithm for capture, hashing and UI.
/// Never resolves symlinks, never collapses `.` / `..`, never reads the file system.
public enum FilePathNormalizer {
    /// Decoded path of a `file:` URL string, extracted exactly once (no second percent-decoding).
    ///
    /// Callers on macOS convert file *reference* URLs (`file:///.file/id=…`) to path URLs first.
    public static func path(fromFileURLString string: String) -> String? {
        guard let url = URL(string: string), url.isFileURL else { return nil }
        let path = url.path(percentEncoded: false)
        return path.isEmpty ? nil : path
    }

    /// A legacy `NSFilenamesPboardType` entry is a file-system path, not a URL: kept verbatim.
    public static func path(fromLegacyFilename string: String) -> String? {
        string.isEmpty || string.utf8.contains(0) ? nil : string
    }

    /// `NSFilenamesPboardType` payload: a property list array of path strings.
    public static func paths(fromFilenamesPropertyList data: Data) -> [String]? {
        guard let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let strings = object as? [String] else { return nil }
        let paths = strings.compactMap(path(fromLegacyFilename:))
        return paths.count == strings.count && !paths.isEmpty ? paths : nil
    }

    /// `public.file-url` payload: the UTF-8 URL string, possibly NUL-terminated.
    public static func paths(fromFileURLData data: Data) -> [String]? {
        var bytes = data[...]
        while bytes.last == 0 { bytes = bytes.dropLast() }
        guard let string = String(validating: bytes, as: UTF8.self),
              let path = path(fromFileURLString: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return [path]
    }

    /// Same validation as capture, used before Restore (§3.5): non-empty, no NUL.
    public static func isValidStoredPath(_ path: String) -> Bool {
        !path.isEmpty && !path.utf8.contains(0)
    }

    /// Equal lists → that list; different → the `public.file-url` list; never a union (§3.3).
    public static func coalesce(fileURLPaths: [String]?, filenamesPaths: [String]?) -> [String]? {
        fileURLPaths ?? filenamesPaths
    }
}
