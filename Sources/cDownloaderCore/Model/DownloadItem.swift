import Foundation

public enum DownloadStatus: String, Codable, Sendable, CaseIterable {
    /// Added or paused; not running.
    case stopped
    /// Picked by a running queue and waiting for a free slot or a retry.
    case waiting
    case downloading
    case completed
    case failed
}

public enum DownloadKind: Codable, Sendable, Equatable {
    case file
    /// An HLS stream; `variantIndex` nil means "highest bandwidth".
    case hls(variantIndex: Int?)
    /// A video page (YouTube) that yt-dlp turns into a file of the chosen quality.
    case webVideo(quality: VideoQuality)
}

/// The picture size asked of a video site; `audio` keeps only the sound.
public enum VideoQuality: String, Codable, Sendable, CaseIterable {
    case best
    case p1080 = "1080"
    case p720 = "720"
    case p480 = "480"
    case p360 = "360"
    case audio

    /// A quality saved by a newer version reads as the best one, so the download list still loads.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VideoQuality(rawValue: raw) ?? .best
    }

    /// The tallest picture allowed, or nil for no limit (and for sound only).
    public var maxHeight: Int? {
        switch self {
        case .best, .audio: nil
        case .p1080: 1080
        case .p720: 720
        case .p480: 480
        case .p360: 360
        }
    }
}

/// Saved state of one segment: bytes `start..<end` of the file, of which `downloaded` are written.
public struct SegmentRecord: Codable, Sendable, Equatable {
    public var start: Int64
    public var end: Int64
    public var downloaded: Int64

    public init(start: Int64, end: Int64, downloaded: Int64 = 0) {
        self.start = start
        self.end = end
        self.downloaded = downloaded
    }

    public var position: Int64 { start + downloaded }
    public var remaining: Int64 { max(0, end - position) }
    public var isFinished: Bool { position >= end }
}

/// One entry of the download list.
public struct DownloadItem: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var url: URL
    public var finalURL: URL?
    public var referer: String?
    public var userAgent: String?
    public var cookies: String?
    public var extraHeaders: [String: String]
    /// The password lives in the secret store under `credentialKey`.
    public var username: String?
    public var fileName: String
    /// Folder path the finished file is moved to.
    public var directory: String
    public var categoryID: String?
    public var descriptionText: String
    public var queueID: UUID?
    public var kind: DownloadKind
    public var status: DownloadStatus
    public var errorMessage: String?
    public var totalBytes: Int64?
    public var downloadedBytes: Int64
    public var resumable: Bool
    public var segments: [SegmentRecord]
    public var etag: String?
    public var lastModified: String?
    public var dateAdded: Date
    public var lastTry: Date?
    public var dateCompleted: Date?
    public var maxConnections: Int?
    /// Per-download speed limit in bytes per second; nil means none.
    public var speedLimit: Int64?
    public var retryCount: Int
    /// Waiting for the browser to supply a fresh address for an expired link.
    public var awaitingAddressRefresh: Bool

    public init(
        id: UUID = UUID(),
        url: URL,
        fileName: String,
        directory: String,
        dateAdded: Date = Date()
    ) {
        self.id = id
        self.url = url
        self.finalURL = nil
        self.referer = nil
        self.userAgent = nil
        self.cookies = nil
        self.extraHeaders = [:]
        self.username = nil
        self.fileName = fileName
        self.directory = directory
        self.categoryID = nil
        self.descriptionText = ""
        self.queueID = nil
        self.kind = .file
        self.status = .stopped
        self.errorMessage = nil
        self.totalBytes = nil
        self.downloadedBytes = 0
        self.resumable = false
        self.segments = []
        self.etag = nil
        self.lastModified = nil
        self.dateAdded = dateAdded
        self.lastTry = nil
        self.dateCompleted = nil
        self.maxConnections = nil
        self.speedLimit = nil
        self.retryCount = 0
        self.awaitingAddressRefresh = false
    }

    public var credentialKey: String { "download.\(id.uuidString)" }

    public var destinationURL: URL {
        URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(fileName)
    }

    public var progress: Double {
        guard let totalBytes, totalBytes > 0 else { return status == .completed ? 1 : 0 }
        return min(1, Double(downloadedBytes) / Double(totalBytes))
    }
}

extension DownloadItem {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(URL.self, forKey: .url)
        fileName = try c.decode(String.self, forKey: .fileName)
        directory = try c.decode(String.self, forKey: .directory)
        dateAdded = try c.value(.dateAdded, default: Date())
        finalURL = try c.decodeIfPresent(URL.self, forKey: .finalURL)
        referer = try c.decodeIfPresent(String.self, forKey: .referer)
        userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent)
        cookies = try c.decodeIfPresent(String.self, forKey: .cookies)
        extraHeaders = try c.value(.extraHeaders, default: [:])
        username = try c.decodeIfPresent(String.self, forKey: .username)
        categoryID = try c.decodeIfPresent(String.self, forKey: .categoryID)
        descriptionText = try c.value(.descriptionText, default: "")
        queueID = try c.decodeIfPresent(UUID.self, forKey: .queueID)
        kind = try c.value(.kind, default: .file)
        status = try c.value(.status, default: .stopped)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        totalBytes = try c.decodeIfPresent(Int64.self, forKey: .totalBytes)
        downloadedBytes = try c.value(.downloadedBytes, default: 0)
        resumable = try c.value(.resumable, default: false)
        segments = try c.value(.segments, default: [])
        etag = try c.decodeIfPresent(String.self, forKey: .etag)
        lastModified = try c.decodeIfPresent(String.self, forKey: .lastModified)
        lastTry = try c.decodeIfPresent(Date.self, forKey: .lastTry)
        dateCompleted = try c.decodeIfPresent(Date.self, forKey: .dateCompleted)
        maxConnections = try c.decodeIfPresent(Int.self, forKey: .maxConnections)
        speedLimit = try c.decodeIfPresent(Int64.self, forKey: .speedLimit)
        retryCount = try c.value(.retryCount, default: 0)
        awaitingAddressRefresh = try c.value(.awaitingAddressRefresh, default: false)
    }
}

extension KeyedDecodingContainer {
    /// Decodes a value, falling back to `fallback` when the key is missing (older files).
    func value<T: Decodable>(_ key: Key, default fallback: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback()
    }
}
