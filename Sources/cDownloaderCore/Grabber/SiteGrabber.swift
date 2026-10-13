import Foundation

/// Network access for the grabber, replaceable in tests.
public protocol GrabberFetching: Sendable {
    /// Downloads a page. Returns nil html for non-HTML responses.
    func page(_ url: URL) async throws -> (html: String?, finalURL: URL)
    /// Size and type of a file without downloading it.
    func info(_ url: URL, referer: URL) async -> (size: Int64?, contentType: String?)
}

public struct GrabberProgress: Sendable, Equatable {
    public var pagesExplored: Int
    public var filesFound: Int
    public var currentURL: URL?

    public init(pagesExplored: Int, filesFound: Int, currentURL: URL?) {
        self.pagesExplored = pagesExplored
        self.filesFound = filesFound
        self.currentURL = currentURL
    }
}

public struct GrabberResult: Sendable, Equatable {
    public var files: [GrabberFile]
    public var pagesExplored: Int
}

/// Explores a site level by level and collects the files that pass the filters.
public final class SiteGrabber: @unchecked Sendable {
    public let settings: GrabberSettings
    let fetcher: GrabberFetching
    let maxConcurrent: Int
    let maxPages: Int

    public init(settings: GrabberSettings, fetcher: GrabberFetching = URLSessionGrabberFetcher(), maxConcurrent: Int = 4, maxPages: Int = 5000) {
        self.settings = settings
        self.fetcher = fetcher
        self.maxConcurrent = maxConcurrent
        self.maxPages = maxPages
    }

    private struct PageVisit: Sendable {
        var url: URL
        /// Link hops from the start page.
        var depth: Int
        /// Consecutive pages on other sites (0 while on the start site).
        var otherDepth: Int
    }

    private struct Candidate {
        var url: URL
        var referer: URL
    }

    public func run(progress: @escaping @Sendable (GrabberProgress) -> Void = { _ in }) async -> GrabberResult {
        let rules = GrabberRules(settings: settings)
        var visited: Set<String> = [Self.key(settings.startURL)]
        var seenFiles = Set<String>()
        var candidates: [Candidate] = []
        var level = [PageVisit(url: settings.startURL, depth: 0, otherDepth: 0)]
        var explored = 0

        while !level.isEmpty, explored < maxPages, !Task.isCancelled {
            let pages = await fetchPages(level)
            var nextLevel: [PageVisit] = []
            for (visit, links) in pages {
                guard let links else { continue }
                explored += 1
                for link in links {
                    if rules.isWantedFileType(link), rules.acceptsFile(link), seenFiles.insert(Self.key(link)).inserted {
                        candidates.append(Candidate(url: link, referer: visit.url))
                    }
                    guard rules.looksLikePage(link), !visited.contains(Self.key(link)) else { continue }
                    let onStart = rules.isOnStartSite(link)
                    let next = PageVisit(url: link, depth: visit.depth + 1, otherDepth: onStart ? 0 : visit.otherDepth + 1)
                    let withinLevels = onStart ? next.depth < settings.levelsOnThisSite : next.otherDepth <= settings.levelsOnOtherSites
                    guard withinLevels, rules.mayExplore(link) else { continue }
                    visited.insert(Self.key(link))
                    nextLevel.append(next)
                }
                progress(GrabberProgress(pagesExplored: explored, filesFound: candidates.count, currentURL: visit.url))
            }
            level = nextLevel
        }

        var files = await describe(candidates).filter { rules.acceptsSize($0.size) }
        if settings.hideDuplicates { files = GrabberRules.removingDuplicates(files) }
        return GrabberResult(files: files, pagesExplored: explored)
    }

    private static func key(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url?.absoluteString ?? url.absoluteString
    }

    /// Fetches one level of pages, a few at a time, keeping the original order. nil links mean the page failed.
    private func fetchPages(_ visits: [PageVisit]) async -> [(PageVisit, [URL]?)] {
        await withTaskGroup(of: (Int, [URL]?).self) { group in
            var results = [(PageVisit, [URL]?)](repeating: (visits.first!, nil), count: visits.count)
            var next = 0
            func addNext() {
                guard next < visits.count else { return }
                let index = next
                let visit = visits[index]
                next += 1
                group.addTask { [fetcher] in
                    guard let page = try? await fetcher.page(visit.url) else { return (index, nil) }
                    guard let html = page.html else { return (index, []) }
                    return (index, HTMLLinkExtractor.links(in: html, baseURL: page.finalURL))
                }
            }
            for _ in 0..<maxConcurrent { addNext() }
            while let (index, links) = await group.next() {
                results[index] = (visits[index], links)
                addNext()
            }
            return results
        }
    }

    /// Looks up size and type for each found file and builds the result rows.
    private func describe(_ candidates: [Candidate]) async -> [GrabberFile] {
        await withTaskGroup(of: (Int, Int64?, String?).self) { group in
            var sizes = [(Int64?, String?)](repeating: (nil, nil), count: candidates.count)
            var next = 0
            func addNext() {
                guard next < candidates.count else { return }
                let index = next
                let candidate = candidates[index]
                next += 1
                group.addTask { [fetcher] in
                    let info = await fetcher.info(candidate.url, referer: candidate.referer)
                    return (index, info.size, info.contentType)
                }
            }
            for _ in 0..<maxConcurrent { addNext() }
            while let (index, size, type) = await group.next() {
                sizes[index] = (size, type)
                addNext()
            }
            return candidates.enumerated().map { index, candidate in
                let relative = GrabberRules.relativePath(for: candidate.url, useOriginalSubfolders: settings.useOriginalSubfolders)
                return GrabberFile(url: candidate.url, referer: candidate.referer, size: sizes[index].0, contentType: sizes[index].1, checked: true, relativePath: relative)
            }
        }
    }
}

public struct URLSessionGrabberFetcher: GrabberFetching {
    let session: URLSession
    let userAgent: String

    public init(session: URLSession = .shared, userAgent: String = EngineConfiguration.defaultUserAgent) {
        self.session = session
        self.userAgent = userAgent
    }

    public func page(_ url: URL) async throws -> (html: String?, finalURL: URL) {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        guard (200...299).contains(http?.statusCode ?? 200) else { throw DownloadFailure.http(http?.statusCode ?? 0) }
        let isHTML = (response.mimeType ?? "").contains("html") || response.mimeType == nil
        let text = isHTML ? (String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)) : nil
        return (text, response.url ?? url)
    }

    public func info(_ url: URL, referer: URL) async -> (size: Int64?, contentType: String?) {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        guard let (_, response) = try? await session.data(for: request) else { return (nil, nil) }
        let length = response.expectedContentLength
        return (length >= 0 ? length : nil, response.mimeType)
    }
}
