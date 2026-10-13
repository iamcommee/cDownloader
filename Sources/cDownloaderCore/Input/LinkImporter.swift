import Foundation

/// Finds download links in text and reads and writes link lists.
public enum LinkImporter {
    /// Every http, https and ftp address in free text, de-duplicated, in first-seen order.
    public static func extractURLs(from text: String) -> [URL] {
        let pattern = #"(?i)\b(?:https?|ftp)://[^\s<>"'`{}|\\^\[\]]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var seen = Set<String>()
        var result: [URL] = []
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let candidate = trimTrailingPunctuation(String(text[matchRange]))
            guard let url = URL(string: candidate), url.host?.isEmpty == false, seen.insert(candidate).inserted else { continue }
            result.append(url)
        }
        return result
    }

    /// Drops sentence punctuation stuck to the end of a link, keeping balanced parentheses.
    static func trimTrailingPunctuation(_ link: String) -> String {
        var link = link
        while let last = link.last {
            if ".,;:!?'\"".contains(last) {
                link.removeLast()
            } else if last == ")" {
                let opens = link.filter { $0 == "(" }.count
                let closes = link.filter { $0 == ")" }.count
                guard closes > opens else { break }
                link.removeLast()
            } else {
                break
            }
        }
        return link
    }

    /// One address per line; blank and invalid lines are skipped.
    public static func importPlainText(_ text: String) -> [URL] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
                  ["http", "https", "ftp"].contains(scheme), url.host?.isEmpty == false
            else { return nil }
            return url
        }
    }

    public static func exportPlainText(_ urls: [URL]) -> String {
        urls.map { $0.absoluteString + "\n" }.joined()
    }
}

/// One entry of an IDM export file (.ef2).
public struct EF2Entry: Sendable, Equatable {
    public var url: URL
    public var referer: String?
    public var userAgent: String?
    public var cookie: String?

    public init(url: URL, referer: String? = nil, userAgent: String? = nil, cookie: String? = nil) {
        self.url = url
        self.referer = referer
        self.userAgent = userAgent
        self.cookie = cookie
    }
}

/// Reads and writes the IDM `.ef2` export format so lists can move between IDM and cDownloader.
public enum EF2Codec {
    public static func encode(_ entries: [EF2Entry]) -> Data {
        var text = ""
        for entry in entries {
            text += "<\r\n\(entry.url.absoluteString)\r\n"
            if let referer = entry.referer { text += "referer: \(referer)\r\n" }
            if let userAgent = entry.userAgent { text += "User-Agent: \(userAgent)\r\n" }
            if let cookie = entry.cookie { text += "cookie: \(cookie)\r\n" }
            text += ">\r\n"
        }
        return Data(text.utf8)
    }

    public static func decode(_ data: Data) -> [EF2Entry] {
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        var entries: [EF2Entry] = []
        var block: [String]?
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "<" {
                block = []
            } else if line == ">" {
                if let block, let entry = entry(from: block) { entries.append(entry) }
                block = nil
            } else if !line.isEmpty {
                block?.append(line)
            }
        }
        return entries
    }

    private static func entry(from lines: [String]) -> EF2Entry? {
        guard let first = lines.first, let url = URL(string: first), url.scheme != nil, url.host?.isEmpty == false else { return nil }
        var entry = EF2Entry(url: url)
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "referer": entry.referer = value
            case "user-agent": entry.userAgent = value
            case "cookie": entry.cookie = value
            default: break
            }
        }
        return entry
    }
}
