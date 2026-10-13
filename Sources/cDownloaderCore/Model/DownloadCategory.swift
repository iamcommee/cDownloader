import Foundation

public struct DownloadCategory: Codable, Sendable, Equatable, Identifiable, Hashable {
    public static let generalID = "general"

    public var id: String
    public var name: String
    /// Lowercase extensions without dots; `*` wildcards allowed (for example "r0*").
    public var extensions: [String]
    /// Default folder for files of this category.
    public var folder: String
    public var isBuiltIn: Bool

    public init(id: String = UUID().uuidString, name: String, extensions: [String], folder: String, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.extensions = extensions
        self.folder = folder
        self.isBuiltIn = isBuiltIn
    }
}

public enum CategoryCatalog {
    /// The six built-in categories, with folders under `root` (normally ~/Downloads).
    public static func defaults(root: URL) -> [DownloadCategory] {
        func folder(_ name: String) -> String { root.appendingPathComponent(name, isDirectory: true).path }
        return [
            DownloadCategory(id: DownloadCategory.generalID, name: "General", extensions: [], folder: root.path, isBuiltIn: true),
            DownloadCategory(
                id: "compressed", name: "Compressed",
                extensions: ["zip", "rar", "7z", "gz", "tgz", "bz2", "xz", "zst", "tar", "arj", "ace", "lzh", "sit", "sitx", "sea", "z", "r0*", "r1*"],
                folder: folder("Compressed"), isBuiltIn: true
            ),
            DownloadCategory(
                id: "documents", name: "Documents",
                extensions: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pps", "txt", "rtf", "odt", "ods", "odp", "pages", "numbers", "key", "epub", "csv", "md"],
                folder: folder("Documents"), isBuiltIn: true
            ),
            DownloadCategory(
                id: "music", name: "Music",
                extensions: ["mp3", "wav", "wma", "mpa", "ram", "ra", "aac", "aif", "aiff", "m4a", "flac", "ogg", "opus"],
                folder: folder("Music"), isBuiltIn: true
            ),
            DownloadCategory(
                id: "programs", name: "Programs",
                extensions: ["dmg", "pkg", "mpkg", "app", "exe", "msi", "iso", "img", "apk", "deb", "rpm", "bin"],
                folder: folder("Programs"), isBuiltIn: true
            ),
            DownloadCategory(
                id: "video", name: "Video",
                extensions: ["mp4", "m4v", "mov", "qt", "avi", "mpg", "mpe", "mpeg", "asf", "wmv", "rm", "rmvb", "flv", "webm", "ogv", "mkv", "ts", "3gp", "m3u8"],
                folder: folder("Video"), isBuiltIn: true
            ),
        ]
    }

    /// The category whose extension list matches the file's last extension, or General.
    public static func suggest(fileName: String, in categories: [DownloadCategory]) -> DownloadCategory? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let general = categories.first { $0.id == DownloadCategory.generalID } ?? categories.first
        guard !ext.isEmpty else { return general }
        return categories.first { category in
            category.id != DownloadCategory.generalID && Wildcard.matchesAny(category.extensions, ext)
        } ?? general
    }
}
