import Foundation

/// Everything the four-step grabber wizard collects.
public struct GrabberSettings: Codable, Sendable, Equatable {
    // Step 1
    public var startURL: URL
    public var templateName: String
    // Step 2
    public var saveFolder: String
    public var useOriginalSubfolders: Bool
    // Step 3: which pages to explore
    /// Levels of pages to explore on the start site; 1 explores only the start page.
    public var levelsOnThisSite: Int
    /// Levels of pages to explore on other sites; 0 never leaves the start site.
    public var levelsOnOtherSites: Int
    public var dontExploreParentDirectories: Bool
    public var exploreWholeMainDomain: Bool
    public var exploreInclude: [String]
    public var exploreExclude: [String]
    public var logoutPatterns: [String]
    // Step 4: which files to keep
    public var fileTypes: [String]
    public var fileInclude: [String]
    public var fileExclude: [String]
    public var minimumSize: Int64?
    public var maximumSize: Int64?
    public var filesOnThisSiteOnly: Bool
    public var hideDuplicates: Bool
    public var downloadAllAtOnce: Bool

    public init(startURL: URL, saveFolder: String, fileTypes: [String], templateName: String = "Custom") {
        self.startURL = startURL
        self.templateName = templateName
        self.saveFolder = saveFolder
        self.useOriginalSubfolders = false
        self.levelsOnThisSite = 2
        self.levelsOnOtherSites = 0
        self.dontExploreParentDirectories = false
        self.exploreWholeMainDomain = false
        self.exploreInclude = []
        self.exploreExclude = []
        self.logoutPatterns = ["*logout*", "*logoff*", "*signout*", "*sign-out*"]
        self.fileTypes = fileTypes
        self.fileInclude = []
        self.fileExclude = []
        self.minimumSize = nil
        self.maximumSize = nil
        self.filesOnThisSiteOnly = false
        self.hideDuplicates = true
        self.downloadAllAtOnce = false
    }
}

public struct GrabberTemplate: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var fileTypes: [String]
    public var levelsOnThisSite: Int

    public static let all: [GrabberTemplate] = [
        GrabberTemplate(name: "All images from a web site", fileTypes: ["jpg", "jpeg", "png", "gif", "webp", "bmp", "svg", "tif", "tiff"], levelsOnThisSite: 3),
        GrabberTemplate(name: "All audio files from a web site", fileTypes: ["mp3", "m4a", "aac", "ogg", "wav", "flac", "wma"], levelsOnThisSite: 3),
        GrabberTemplate(name: "All video files from a web site", fileTypes: ["mp4", "m4v", "mov", "webm", "mkv", "avi", "wmv", "flv"], levelsOnThisSite: 3),
        GrabberTemplate(name: "All documents from a web site", fileTypes: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "epub"], levelsOnThisSite: 3),
        GrabberTemplate(name: "Complete web site (for offline browsing)", fileTypes: ["*"], levelsOnThisSite: 20),
        GrabberTemplate(name: "Custom", fileTypes: [], levelsOnThisSite: 2),
    ]
}

/// One file the grabber found.
public struct GrabberFile: Codable, Sendable, Equatable, Identifiable {
    public var id: URL { url }
    public var url: URL
    /// The page the link was found on (sent as Referer).
    public var referer: URL
    public var size: Int64?
    public var contentType: String?
    public var checked: Bool
    /// Path below the save folder ("sub/dir/name.jpg" or just "name.jpg").
    public var relativePath: String

    /// Where the file goes inside `folder`, or nil when its path would leave that folder.
    public func destination(in folder: URL) -> URL? {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\\") }) else { return nil }
        let base = folder.standardizedFileURL.path
        let target = folder.appendingPathComponent(relativePath).standardizedFileURL
        guard target.path.hasPrefix(base.hasSuffix("/") ? base : base + "/") else { return nil }
        return target
    }
}

public struct GrabberProject: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var settings: GrabberSettings
    public var files: [GrabberFile]
    public var pagesExplored: Int
    public var lastRun: Date?
    public var schedule: QueueSchedule?

    public init(id: UUID = UUID(), name: String, settings: GrabberSettings, files: [GrabberFile] = [], pagesExplored: Int = 0, lastRun: Date? = nil, schedule: QueueSchedule? = nil) {
        self.id = id
        self.name = name
        self.settings = settings
        self.files = files
        self.pagesExplored = pagesExplored
        self.lastRun = lastRun
        self.schedule = schedule
    }
}
