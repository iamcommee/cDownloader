import Foundation

/// Size and validators of the server copy, for synchronization queues.
public struct RemoteFileInfo: Sendable, Equatable {
    public var size: Int64?
    public var lastModified: String?
    public var etag: String?

    public init(size: Int64?, lastModified: String?, etag: String?) {
        self.size = size
        self.lastModified = lastModified
        self.etag = etag
    }

    /// True when any value the server reports differs from what was downloaded.
    public static func hasChanged(item: DownloadItem, remote: RemoteFileInfo) -> Bool {
        if let size = remote.size, let known = item.totalBytes, size != known { return true }
        if let modified = remote.lastModified, let known = item.lastModified, modified != known { return true }
        if let etag = remote.etag, let known = item.etag, etag != known { return true }
        return false
    }
}
