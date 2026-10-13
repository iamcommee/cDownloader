import Compression
import Foundation

public struct ZipEntry: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var compressedSize: UInt64
    public var uncompressedSize: UInt64
    public var method: UInt16
    public var crc32: UInt32
    public var localHeaderOffset: UInt64
    public var isEncrypted: Bool
    public var isDirectory: Bool { name.hasSuffix("/") }
}

public enum ZipPreviewError: Error, Equatable {
    case notAZip
    case truncated
    case rangesNotSupported
    case unsupportedMethod(UInt16)
    case encrypted
    case checksumMismatch
    case tooLarge
    case network(String)

    public var message: String {
        switch self {
        case .notAZip: "This file is not a zip archive"
        case .truncated: "The zip archive is incomplete or damaged"
        case .rangesNotSupported: "The server does not support partial downloads, so the archive cannot be previewed"
        case .unsupportedMethod(let method): "This file uses an unsupported compression method (\(method))"
        case .encrypted: "This file is password-protected"
        case .checksumMismatch: "The extracted file is damaged (checksum mismatch)"
        case .tooLarge: "This part of the archive is too large to preview"
        case .network(let text): "Network error: \(text)"
        }
    }
}

/// Fetches byte ranges of a remote file.
public protocol RangeFetching: Sendable {
    /// `range` uses HTTP Range syntax without the "bytes=" prefix, for example "-1024" or "100-199".
    func fetch(_ url: URL, range: String) async throws -> (data: Data, totalSize: Int64?)
}

public struct HTTPRangeFetcher: RangeFetching {
    let session: URLSession
    let headers: [String: String]

    public init(session: URLSession = .shared, headers: [String: String] = [:]) {
        self.session = session
        self.headers = headers
    }

    public func fetch(_ url: URL, range: String) async throws -> (data: Data, totalSize: Int64?) {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=\(range)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ZipPreviewError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ZipPreviewError.network("No HTTP response") }
        guard http.statusCode == 206 else {
            if http.statusCode == 200 { throw ZipPreviewError.rangesNotSupported }
            throw ZipPreviewError.network("HTTP \(http.statusCode)")
        }
        let total = http.value(forHTTPHeaderField: "Content-Range").flatMap(HTTPTransport.parseContentRange)?.total
        return (data, total)
    }
}

/// Lists and extracts files of a remote zip archive using only a few small range requests.
public struct RemoteZipPreview: Sendable {
    public let url: URL
    let fetcher: RangeFetching

    public init(url: URL, fetcher: RangeFetching = HTTPRangeFetcher()) {
        self.url = url
        self.fetcher = fetcher
    }

    /// Largest table of contents and largest single file the preview will download.
    public static let maxDirectoryBytes: UInt64 = 64 * 1024 * 1024
    public static let maxEntryBytes: UInt64 = 512 * 1024 * 1024

    private static let endRecordSignature: UInt32 = 0x0605_4B50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    private static let zip64EndSignature: UInt32 = 0x0606_4B50
    private static let centralSignature: UInt32 = 0x0201_4B50
    private static let localSignature: UInt32 = 0x0403_4B50

    /// Reads the end of the archive, finds the central directory and parses every entry.
    /// Every number comes from the server or the archive, so all arithmetic is checked.
    public func listEntries() async throws -> [ZipEntry] {
        let tailLength = 22 + 65_535 + 20
        let (tail, reportedTotal) = try await fetcher.fetch(url, range: "-\(tailLength)")
        let total: UInt64
        if let reportedTotal {
            guard let value = UInt64(exactly: reportedTotal) else { throw ZipPreviewError.truncated }
            total = value
        } else {
            total = UInt64(tail.count)
        }
        guard total >= UInt64(tail.count) else { throw ZipPreviewError.truncated }
        let tailStart = total - UInt64(tail.count)
        let tailBytes = ZipBytes(tail)
        guard let end = Self.findEndRecord(tailBytes) else { throw ZipPreviewError.notAZip }

        var count = UInt64(try tailBytes.u16(end + 10))
        var size = UInt64(try tailBytes.u32(end + 12))
        var offset = UInt64(try tailBytes.u32(end + 16))
        if count == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF {
            guard end >= 20, try tailBytes.u32(end - 20) == Self.zip64LocatorSignature else { throw ZipPreviewError.truncated }
            let recordOffset = try tailBytes.u64(end - 20 + 8)
            let record = ZipBytes(try await bytes(at: recordOffset, length: 56, tail: tail, tailStart: tailStart, total: total))
            guard try record.u32(0) == Self.zip64EndSignature else { throw ZipPreviewError.truncated }
            count = try record.u64(32)
            size = try record.u64(40)
            offset = try record.u64(48)
        }
        guard size <= Self.maxDirectoryBytes else { throw ZipPreviewError.tooLarge }
        guard try Self.add(offset, size) <= total, count <= size / 46 + 1 else { throw ZipPreviewError.truncated }
        guard size > 0 else { return [] }
        let directory = ZipBytes(try await bytes(at: offset, length: size, tail: tail, tailStart: tailStart, total: total))
        return try Self.parseCentralDirectory(directory, count: count)
    }

    /// Downloads just one entry and returns its uncompressed bytes.
    public func extract(_ entry: ZipEntry) async throws -> Data {
        guard !entry.isEncrypted else { throw ZipPreviewError.encrypted }
        guard entry.method == 0 || entry.method == 8 else { throw ZipPreviewError.unsupportedMethod(entry.method) }
        guard entry.compressedSize <= Self.maxEntryBytes, entry.uncompressedSize <= Self.maxEntryBytes else { throw ZipPreviewError.tooLarge }
        let header = ZipBytes(try await bytes(at: entry.localHeaderOffset, length: 30, tail: nil, tailStart: 0, total: nil))
        guard try header.u32(0) == Self.localSignature else { throw ZipPreviewError.truncated }
        let start = try Self.add(entry.localHeaderOffset, 30 + UInt64(try header.u16(26)) + UInt64(try header.u16(28)))
        let compressed = entry.compressedSize == 0 ? Data() : try await bytes(at: start, length: entry.compressedSize, tail: nil, tailStart: 0, total: nil)
        let data = entry.method == 0 ? compressed : try Self.inflate(compressed, limit: Int(entry.uncompressedSize))
        guard UInt64(data.count) == entry.uncompressedSize, CRC32.checksum(data) == entry.crc32 else {
            throw ZipPreviewError.checksumMismatch
        }
        return data
    }

    static func add(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        if overflow { throw ZipPreviewError.truncated }
        return sum
    }

    /// Raw deflate with an output limit, so a tiny "zip bomb" cannot fill the memory.
    static func inflate(_ data: Data, limit: Int) throws -> Data {
        final class Sink: @unchecked Sendable { var data = Data() }
        let sink = Sink()
        do {
            let filter = try OutputFilter(.decompress, using: .zlib) { chunk in
                guard let chunk else { return }
                sink.data.append(chunk)
                if sink.data.count > limit { throw ZipPreviewError.tooLarge }
            }
            try filter.write(data)
            try filter.finalize()
        } catch let error as ZipPreviewError {
            throw error
        } catch {
            throw ZipPreviewError.truncated
        }
        return sink.data
    }

    /// Bytes `offset..<offset+length`, taken from the already-downloaded tail when possible.
    private func bytes(at offset: UInt64, length: UInt64, tail: Data?, tailStart: UInt64, total: UInt64?) async throws -> Data {
        guard length > 0, length <= Self.maxEntryBytes else { throw length == 0 ? ZipPreviewError.truncated : ZipPreviewError.tooLarge }
        let end = try Self.add(offset, length)
        if let total, end > total { throw ZipPreviewError.truncated }
        if let tail, offset >= tailStart, end <= tailStart + UInt64(tail.count) {
            let from = tail.startIndex + Int(offset - tailStart)
            return tail.subdata(in: from..<(from + Int(length)))
        }
        let (data, _) = try await fetcher.fetch(url, range: "\(offset)-\(end - 1)")
        guard UInt64(data.count) == length else { throw ZipPreviewError.truncated }
        return data
    }

    /// Position of the end-of-central-directory record whose comment length fits the data exactly.
    static func findEndRecord(_ bytes: ZipBytes) -> Int? {
        guard bytes.count >= 22 else { return nil }
        var index = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 65_535)
        while index >= lowest {
            if (try? bytes.u32(index)) == endRecordSignature,
               let commentLength = try? bytes.u16(index + 20),
               index + 22 + Int(commentLength) == bytes.count {
                return index
            }
            index -= 1
        }
        return nil
    }

    static func parseCentralDirectory(_ bytes: ZipBytes, count: UInt64) throws -> [ZipEntry] {
        var entries: [ZipEntry] = []
        var position = 0
        for _ in 0..<count {
            guard try bytes.u32(position) == centralSignature else { throw ZipPreviewError.truncated }
            let flags = try bytes.u16(position + 8)
            let method = try bytes.u16(position + 10)
            let crc = try bytes.u32(position + 16)
            var compressed = UInt64(try bytes.u32(position + 20))
            var uncompressed = UInt64(try bytes.u32(position + 24))
            let nameLength = Int(try bytes.u16(position + 28))
            let extraLength = Int(try bytes.u16(position + 30))
            let commentLength = Int(try bytes.u16(position + 32))
            var localOffset = UInt64(try bytes.u32(position + 42))
            let nameData = try bytes.slice(position + 46, nameLength)
            let utf8 = flags & (1 << 11) != 0
            let name = (utf8 ? String(data: nameData, encoding: .utf8) : nil)
                ?? String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1) ?? ""

            // ZIP64 extra field: only the values stored as 0xFFFFFFFF appear, in this order.
            var extra = position + 46 + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let tag = try bytes.u16(extra)
                let length = Int(try bytes.u16(extra + 2))
                if tag == 0x0001 {
                    var field = extra + 4
                    if uncompressed == 0xFFFF_FFFF { uncompressed = try bytes.u64(field); field += 8 }
                    if compressed == 0xFFFF_FFFF { compressed = try bytes.u64(field); field += 8 }
                    if localOffset == 0xFFFF_FFFF { localOffset = try bytes.u64(field) }
                }
                extra += 4 + length
            }

            entries.append(ZipEntry(
                name: name,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                method: method,
                crc32: crc,
                localHeaderOffset: localOffset,
                isEncrypted: flags & 1 != 0
            ))
            position = extraEnd + commentLength
        }
        return entries
    }
}

/// Bounds-checked little-endian reads.
struct ZipBytes {
    let data: Data

    init(_ data: Data) {
        self.data = data
    }

    var count: Int { data.count }

    func slice(_ offset: Int, _ length: Int) throws -> Data {
        guard offset >= 0, length >= 0, offset + length <= data.count else { throw ZipPreviewError.truncated }
        let start = data.startIndex + offset
        return data.subdata(in: start..<(start + length))
    }

    private func value<T: FixedWidthInteger>(_ offset: Int, _ type: T.Type) throws -> T {
        let raw = try slice(offset, MemoryLayout<T>.size)
        return T(littleEndian: raw.withUnsafeBytes { $0.loadUnaligned(as: T.self) })
    }

    func u16(_ offset: Int) throws -> UInt16 { try value(offset, UInt16.self) }
    func u32(_ offset: Int) throws -> UInt32 { try value(offset, UInt32.self) }
    func u64(_ offset: Int) throws -> UInt64 { try value(offset, UInt64.self) }
}

public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
