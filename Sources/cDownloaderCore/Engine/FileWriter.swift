import Foundation

/// Random-access writes into the partial file using POSIX calls.
final class FileWriter {
    let url: URL
    private var fd: Int32 = -1

    init(url: URL) {
        self.url = url
    }

    var isOpen: Bool { fd >= 0 }

    /// Opens (creating if needed). `truncate` throws away earlier content.
    func open(truncate: Bool) throws {
        close()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var flags = O_RDWR | O_CREAT
        if truncate { flags |= O_TRUNC }
        fd = Darwin.open(url.path, flags, 0o644)
        if fd < 0 { throw DownloadFailure.fileSystem(String(cString: strerror(errno))) }
    }

    /// Sets the file length up front so segments can be written anywhere (sparse on APFS).
    func setLength(_ length: Int64) throws {
        guard fd >= 0 else { return }
        if ftruncate(fd, off_t(length)) != 0 { throw DownloadFailure.fileSystem(String(cString: strerror(errno))) }
    }

    func write(_ data: Data, at offset: Int64) throws {
        guard fd >= 0, !data.isEmpty else { return }
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let result = pwrite(fd, buffer.baseAddress!.advanced(by: written), buffer.count - written, off_t(offset) + off_t(written))
                if result < 0 {
                    if errno == EINTR { continue }
                    throw DownloadFailure.fileSystem(String(cString: strerror(errno)))
                }
                written += result
            }
        }
    }

    func sync() {
        if fd >= 0 { fsync(fd) }
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit { close() }
}
