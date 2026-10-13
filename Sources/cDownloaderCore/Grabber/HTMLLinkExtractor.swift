import Foundation

/// Pulls link addresses out of HTML without a full parser.
public enum HTMLLinkExtractor {
    /// Links from href, src, srcset, poster and data attributes, resolved against `<base href>` or `baseURL`,
    /// without fragments, de-duplicated in page order. javascript:, mailto:, tel: and data: links are dropped.
    public static func links(in html: String, baseURL: URL) -> [URL] {
        let tags = tagMatches(in: html)
        var base = baseURL
        if let baseTag = tags.first(where: { $0.name == "base" }), let href = baseTag.attributes["href"],
           let resolved = URL(string: clean(href), relativeTo: baseURL)?.absoluteURL {
            base = resolved
        }
        var seen = Set<String>()
        var result: [URL] = []
        for tag in tags where tag.name != "base" {
            for attribute in linkAttributes[tag.name] ?? [] {
                guard let raw = tag.attributes[attribute] else { continue }
                let values = attribute == "srcset" ? srcsetCandidates(raw) : [raw]
                for value in values {
                    guard let url = resolve(value, base: base), seen.insert(url.absoluteString).inserted else { continue }
                    result.append(url)
                }
            }
        }
        return result
    }

    private static let linkAttributes: [String: [String]] = [
        "a": ["href"], "area": ["href"], "link": ["href"],
        "img": ["src", "srcset", "data-src"], "source": ["src", "srcset"],
        "video": ["src", "poster"], "audio": ["src"], "track": ["src"], "embed": ["src"],
        "iframe": ["src"], "frame": ["src"], "script": ["src"], "object": ["data"],
        "body": ["background"], "table": ["background"], "td": ["background"],
    ]

    private struct Tag {
        var name: String
        var attributes: [String: String]
    }

    private static let tagRegex = try! NSRegularExpression(pattern: #"<\s*([a-zA-Z][a-zA-Z0-9]*)\b([^>]*)>"#)
    private static let attributeRegex = try! NSRegularExpression(pattern: #"([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#)

    private static func tagMatches(in html: String) -> [Tag] {
        let text = html as NSString
        return tagRegex.matches(in: html, range: NSRange(location: 0, length: text.length)).map { match in
            let name = text.substring(with: match.range(at: 1)).lowercased()
            let body = text.substring(with: match.range(at: 2))
            var attributes: [String: String] = [:]
            let bodyText = body as NSString
            for attribute in attributeRegex.matches(in: body, range: NSRange(location: 0, length: bodyText.length)) {
                let key = bodyText.substring(with: attribute.range(at: 1)).lowercased()
                guard attributes[key] == nil else { continue }
                for group in 2...4 where attribute.range(at: group).location != NSNotFound {
                    attributes[key] = bodyText.substring(with: attribute.range(at: group))
                    break
                }
            }
            return Tag(name: name, attributes: attributes)
        }
    }

    private static func srcsetCandidates(_ value: String) -> [String] {
        value.split(separator: ",").compactMap { candidate in
            candidate.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace).first.map(String.init)
        }
    }

    private static func resolve(_ raw: String, base: URL) -> URL? {
        let value = clean(raw)
        guard !value.isEmpty, !value.hasPrefix("#") else { return nil }
        let lower = value.lowercased()
        for scheme in ["javascript:", "mailto:", "tel:", "data:", "about:", "blob:"] where lower.hasPrefix(scheme) { return nil }
        guard let url = URL(string: value, relativeTo: base)?.absoluteURL,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https", "ftp"].contains(scheme)
        else { return nil }
        components.fragment = nil
        return components.url
    }

    /// Decodes common HTML entities and percent-encodes spaces.
    private static func clean(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("&") {
            for (entity, replacement) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">")] {
                text = text.replacingOccurrences(of: entity, with: replacement)
            }
            text = decodeNumericEntities(text)
        }
        return text.replacingOccurrences(of: " ", with: "%20")
    }

    private static func decodeNumericEntities(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") else { return text }
        let source = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            let hex = source.substring(with: match.range(at: 1)) == "x"
            let digits = source.substring(with: match.range(at: 2))
            if let code = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                result.unicodeScalars.append(scalar)
            }
            last = match.range.location + match.range.length
        }
        result += source.substring(from: last)
        return result
    }
}
