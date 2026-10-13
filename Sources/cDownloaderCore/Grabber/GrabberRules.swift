import Foundation

/// The grabber's decisions about pages and files, kept separate from networking.
public struct GrabberRules: Sendable {
    public let settings: GrabberSettings

    public init(settings: GrabberSettings) {
        self.settings = settings
    }

    private static let pageExtensions: Set<String> = ["html", "htm", "shtml", "xhtml", "php", "asp", "aspx", "jsp", "cfm", "cgi", "pl"]

    /// Host plus port; two addresses are on the same site when these match.
    public static func siteKey(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let port = url.port ?? (scheme == "https" ? 443 : scheme == "ftp" ? 21 : 80)
        return "\((url.host ?? "").lowercased()):\(port)"
    }

    /// Last two labels of the host ("www.tonec.com" -> "tonec.com"); IP addresses stay whole.
    public static func mainDomain(of host: String) -> String {
        let labels = host.lowercased().split(separator: ".")
        if labels.count <= 2 || labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return host.lowercased() }
        return labels.suffix(2).joined(separator: ".")
    }

    private var startDirectory: String {
        let path = settings.startURL.path
        guard let slash = path.lastIndex(of: "/") else { return "/" }
        return String(path[...slash])
    }

    private var startDirectoryURL: String {
        var components = URLComponents(url: settings.startURL, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        components?.path = startDirectory
        return components?.url?.absoluteString ?? settings.startURL.absoluteString
    }

    /// Whether the link is a file of a wanted type (as opposed to a page to explore).
    public func isWantedFileType(_ url: URL) -> Bool {
        if settings.fileTypes.contains("*") { return true }
        let ext = url.pathExtension.lowercased()
        return !ext.isEmpty && Wildcard.matchesAny(settings.fileTypes, ext)
    }

    /// Whether the link looks like a web page.
    public func looksLikePage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty || url.path.hasSuffix("/") || Self.pageExtensions.contains(ext)
    }

    /// Counts toward "levels on this site" (same site, or same main domain when that option is on).
    public func isOnStartSite(_ url: URL) -> Bool {
        if Self.siteKey(url) == Self.siteKey(settings.startURL) { return true }
        guard settings.exploreWholeMainDomain, let host = url.host?.lowercased(), let startHost = settings.startURL.host else { return false }
        let domain = Self.mainDomain(of: startHost)
        return host == domain || host.hasSuffix("." + domain)
    }

    /// Path, include/exclude and logout rules for exploring a page (levels are checked by the crawler).
    public func mayExplore(_ url: URL) -> Bool {
        let address = url.absoluteString
        if Wildcard.matchesAny(settings.logoutPatterns, address) { return false }
        if settings.dontExploreParentDirectories, Self.siteKey(url) == Self.siteKey(settings.startURL),
           !url.path.hasPrefix(startDirectory) {
            return false
        }
        if !settings.exploreInclude.isEmpty, !Wildcard.matchesAny(settings.exploreInclude, address) { return false }
        return !Wildcard.matchesAny(settings.exploreExclude, address)
    }

    /// File filters before the size is known.
    public func acceptsFile(_ url: URL) -> Bool {
        if settings.filesOnThisSiteOnly, !isOnStartSite(url) { return false }
        if !settings.fileInclude.isEmpty, !matches(settings.fileInclude, url) { return false }
        return !matches(settings.fileExclude, url)
    }

    /// Patterns match the whole address or just the file name; "<start page>" stands for the start folder.
    private func matches(_ patterns: [String], _ url: URL) -> Bool {
        let expanded = patterns.map { $0.replacingOccurrences(of: "<start page>", with: startDirectoryURL) }
        return Wildcard.matchesAny(expanded, url.absoluteString) || Wildcard.matchesAny(expanded, url.lastPathComponent)
    }

    /// Size filter; an unknown size passes. Both limits are inclusive.
    public func acceptsSize(_ size: Int64?) -> Bool {
        guard let size else { return true }
        if let minimum = settings.minimumSize, size < minimum { return false }
        if let maximum = settings.maximumSize, size > maximum { return false }
        return true
    }

    /// Path below the save folder for a found file.
    /// Every part is cleaned, and ".", ".." and empty parts are dropped, so the result never leaves the save folder
    /// (the decoded path can contain "/" and ".." hidden as %2f and %2e%2e).
    public static func relativePath(for url: URL, useOriginalSubfolders: Bool) -> String {
        let parts = url.path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .map(String.init)
            .filter { $0 != "." && $0 != ".." }
            .map(FileNameResolver.sanitize)
            .filter { !$0.isEmpty }
        let name = parts.last ?? "download"
        guard useOriginalSubfolders, parts.count > 1 else { return name }
        return parts.joined(separator: "/")
    }

    /// Keeps the first file of each (name, size) pair.
    public static func removingDuplicates(_ files: [GrabberFile]) -> [GrabberFile] {
        var seen = Set<String>()
        return files.filter { file in
            seen.insert("\(file.url.lastPathComponent)|\(file.size.map(String.init) ?? "?")").inserted
        }
    }
}
