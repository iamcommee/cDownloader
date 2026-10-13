import Foundation

/// A separate sound track offered next to the video (EXT-X-MEDIA TYPE=AUDIO).
public struct HLSRendition: Sendable, Equatable {
    public var url: URL
    public var name: String?
    public var language: String?
    public var isDefault: Bool

    public init(url: URL, name: String? = nil, language: String? = nil, isDefault: Bool = false) {
        self.url = url
        self.name = name
        self.language = language
        self.isDefault = isDefault
    }
}

public struct HLSVariant: Sendable, Equatable {
    public var url: URL
    public var bandwidth: Int
    public var resolution: String?
    public var codecs: String?
    /// The separate sound track this video needs, when the stream keeps sound apart.
    public var audio: HLSRendition?
}

public struct HLSKey: Sendable, Equatable, Hashable {
    /// "AES-128" or "NONE"; protected methods are rejected while parsing.
    public var method: String
    public var uri: URL?
    /// Explicit IV; nil means "use the segment's sequence number".
    public var iv: Data?
}

public struct HLSSegment: Sendable, Equatable {
    public var url: URL
    public var duration: Double
    public var sequence: Int
    /// Bytes `offset..<offset+length` of `url`, when the playlist uses BYTERANGE.
    public var byteRange: ClosedRange<Int64>?
    public var key: HLSKey?

    /// The IV for AES-128: explicit, or the sequence number as a 16-byte big-endian value.
    public var effectiveIV: Data {
        if let iv = key?.iv { return iv }
        var bytes = [UInt8](repeating: 0, count: 16)
        var value = UInt64(sequence)
        for index in stride(from: 15, through: 8, by: -1) {
            bytes[index] = UInt8(value & 0xFF)
            value >>= 8
        }
        return Data(bytes)
    }
}

public struct HLSMediaPlaylist: Sendable, Equatable {
    public var segments: [HLSSegment]
    /// fMP4 initialization section (EXT-X-MAP), written before all segments.
    public var initSegment: HLSSegment?
    public var mediaSequence: Int
    public var isEnded: Bool

    public var totalDuration: Double { segments.reduce(0) { $0 + $1.duration } }
}

public enum HLSPlaylist: Sendable, Equatable {
    case master([HLSVariant])
    case media(HLSMediaPlaylist)
}

public enum HLSError: Error, Equatable {
    case notAPlaylist
    case liveStreamNotSupported
    case protectedContent
    case noVariants
    case keyFailed(String)
    case segmentFailed(String)
    case playlistFailed(String)

    public var message: String {
        switch self {
        case .notAPlaylist: "This address is not an HLS playlist"
        case .liveStreamNotSupported: "Live streams are not supported; only complete (on-demand) videos can be downloaded"
        case .protectedContent: DownloadFailure.protectedContent.message
        case .noVariants: "The playlist lists no video streams"
        case .keyFailed(let text): "Cannot get the decryption key: \(text)"
        case .segmentFailed(let text): "A video piece could not be downloaded: \(text)"
        case .playlistFailed(let text): "The video playlist could not be loaded: \(text)"
        }
    }
}

public enum HLSParser {
    /// Parses a master or media playlist. Media playlists must be complete (ENDLIST) and not DRM-protected.
    public static func parse(_ text: String, baseURL: URL) throws -> HLSPlaylist {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.first?.hasPrefix("#EXTM3U") == true else { throw HLSError.notAPlaylist }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) {
            return .master(try parseMaster(lines, baseURL: baseURL))
        }
        return .media(try parseMedia(lines, baseURL: baseURL))
    }

    /// The chosen variant, or the one with the highest bandwidth.
    public static func select(_ variants: [HLSVariant], index: Int?) -> HLSVariant? {
        if let index, variants.indices.contains(index) { return variants[index] }
        return variants.max { $0.bandwidth < $1.bandwidth }
    }

    private static func parseMaster(_ lines: [String], baseURL: URL) throws -> [HLSVariant] {
        var variants: [HLSVariant] = []
        var pending: [String: String]?
        // Sound tracks by group: the stream's video lines name the group they need.
        var audioGroups: [String: [HLSRendition]] = [:]
        for line in lines where line.hasPrefix("#EXT-X-MEDIA:") {
            let attributes = attributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
            guard attributes["TYPE"]?.uppercased() == "AUDIO", let group = attributes["GROUP-ID"],
                  let uri = attributes["URI"], let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL
            else { continue }
            let rendition = HLSRendition(url: url, name: attributes["NAME"], language: attributes["LANGUAGE"], isDefault: attributes["DEFAULT"]?.uppercased() == "YES")
            audioGroups[group, default: []].append(rendition)
        }
        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            } else if !line.hasPrefix("#"), let attributes = pending {
                pending = nil
                guard let url = URL(string: line, relativeTo: baseURL)?.absoluteURL else { continue }
                let group = attributes["AUDIO"].flatMap { audioGroups[$0] } ?? []
                variants.append(HLSVariant(
                    url: url,
                    bandwidth: Int(attributes["BANDWIDTH"] ?? "") ?? 0,
                    resolution: attributes["RESOLUTION"],
                    codecs: attributes["CODECS"],
                    audio: group.first(where: \.isDefault) ?? group.first
                ))
            }
        }
        guard !variants.isEmpty else { throw HLSError.noVariants }
        return variants
    }

    private static func parseMedia(_ lines: [String], baseURL: URL) throws -> HLSMediaPlaylist {
        var mediaSequence = 0
        var key: HLSKey?
        var duration = 0.0
        var pendingRange: (length: Int64, offset: Int64?)?
        var previousEnd: [URL: Int64] = [:]
        var segments: [HLSSegment] = []
        var initSegment: HLSSegment?
        var ended = false

        for line in lines {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXT-X-KEY:") {
                key = try parseKey(attributes(String(line.dropFirst("#EXT-X-KEY:".count))), baseURL: baseURL)
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attributes = attributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                guard let uri = attributes["URI"], let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL else { continue }
                let range = attributes["BYTERANGE"].flatMap(parseByteRange).map { range -> ClosedRange<Int64> in
                    let offset = range.offset ?? 0
                    return offset...(offset + range.length - 1)
                }
                initSegment = HLSSegment(url: url, duration: 0, sequence: -1, byteRange: range, key: key)
            } else if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",", maxSplits: 1).first ?? ""
                duration = Double(value.trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingRange = parseByteRange(String(line.dropFirst("#EXT-X-BYTERANGE:".count)))
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                ended = true
            } else if !line.hasPrefix("#") {
                guard let url = URL(string: line, relativeTo: baseURL)?.absoluteURL else { continue }
                var byteRange: ClosedRange<Int64>?
                if let range = pendingRange {
                    let offset = range.offset ?? previousEnd[url] ?? 0
                    byteRange = offset...(offset + range.length - 1)
                    previousEnd[url] = offset + range.length
                }
                segments.append(HLSSegment(url: url, duration: duration, sequence: mediaSequence + segments.count, byteRange: byteRange, key: key))
                duration = 0
                pendingRange = nil
            }
        }
        guard ended else { throw HLSError.liveStreamNotSupported }
        return HLSMediaPlaylist(segments: segments, initSegment: initSegment, mediaSequence: mediaSequence, isEnded: ended)
    }

    /// AES-128 and NONE are accepted; SAMPLE-AES and DRM key systems are refused.
    private static func parseKey(_ attributes: [String: String], baseURL: URL) throws -> HLSKey? {
        let method = attributes["METHOD"]?.uppercased() ?? "NONE"
        if method == "NONE" { return nil }
        if let format = attributes["KEYFORMAT"], format.lowercased() != "identity" { throw HLSError.protectedContent }
        guard method == "AES-128" else { throw HLSError.protectedContent }
        let uri = attributes["URI"].flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
        return HLSKey(method: method, uri: uri, iv: attributes["IV"].flatMap(parseIV))
    }

    /// "len@offset" or "len".
    static func parseByteRange(_ text: String) -> (length: Int64, offset: Int64?)? {
        let parts = text.split(separator: "@")
        guard let length = parts.first.flatMap({ Int64($0) }) else { return nil }
        return (length, parts.count > 1 ? Int64(parts[1]) : nil)
    }

    /// "0x0001...0F" -> 16 bytes, left-padded with zeros.
    static func parseIV(_ text: String) -> Data? {
        var hex = text.lowercased()
        if hex.hasPrefix("0x") { hex.removeFirst(2) }
        guard !hex.isEmpty, hex.count <= 32, hex.allSatisfy(\.isHexDigit) else { return nil }
        hex = String(repeating: "0", count: 32 - hex.count) + hex
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return Data(bytes)
    }

    /// Splits `KEY=VALUE,KEY="quoted, value"` lists.
    static func attributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var current = ""
        var inQuotes = false
        var parts: [String] = []
        for character in text {
            if character == "\"" { inQuotes.toggle() }
            if character == "," && !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        for part in parts {
            guard let equals = part.firstIndex(of: "=") else { continue }
            let key = part[..<equals].trimmingCharacters(in: .whitespaces).uppercased()
            var value = part[part.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            result[key] = value
        }
        return result
    }
}
