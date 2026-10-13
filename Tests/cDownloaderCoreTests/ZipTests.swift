import Foundation
import Testing
@testable import cDownloaderCore

@Suite struct ZipTests {
    let big = Data.pattern(count: 2_000_000, seed: 7)
    let text = Data(String(repeating: "cDownloader zip preview test line.\n", count: 2000).utf8)

    func serve(_ archive: Data, ranges: Bool = true) throws -> LocalHTTPServer {
        let server = try LocalHTTPServer()
        var resource = LocalHTTPServer.Resource(body: archive, contentType: "application/zip")
        resource.supportsRanges = ranges
        server.set("/a.zip", resource)
        return server
    }

    func requestedBytes(_ server: LocalHTTPServer, total: Int) -> Int {
        server.requests(for: "/a.zip").reduce(0) { sum, request in
            guard let header = request.headers["range"], let range = LocalHTTPServer.parseRange(header, total: total) else { return sum + total }
            return sum + range.count
        }
    }

    func sampleArchive(comment: String = "") -> Data {
        var builder = TestZipBuilder()
        builder.entries = [
            .init(name: "big.bin", data: big, method: 0),
            .init(name: "docs/readme.txt", data: text, method: 8),
            .init(name: "docs/", data: Data(), method: 0),
        ]
        builder.comment = comment
        return builder.build()
    }

    @Test func t10_01_listsEntriesUsingOnlyTailAndCentralDirectory() async throws {
        let archive = sampleArchive()
        let server = try serve(archive)
        let entries = try await RemoteZipPreview(url: server.url("/a.zip")).listEntries()
        try #require(entries.map(\.name) == ["big.bin", "docs/readme.txt", "docs/"])
        #expect(entries[0].uncompressedSize == 2_000_000 && entries[0].method == 0)
        #expect(entries[1].uncompressedSize == UInt64(text.count) && entries[1].method == 8)
        #expect(entries[1].compressedSize < entries[1].uncompressedSize)
        #expect(entries[2].isDirectory)
        #expect(requestedBytes(server, total: archive.count) < 100_000)
    }

    @Test func t10_01_commentShiftsEndRecord() async throws {
        let archive = sampleArchive(comment: String(repeating: "c", count: 3000))
        let server = try serve(archive)
        let entries = try await RemoteZipPreview(url: server.url("/a.zip")).listEntries()
        #expect(entries.count == 3)
    }

    @Test func t10_01_zip64SizesAndOffsetsBeyond4GB() async throws {
        let archive = TestZipBuilder.zip64Listing(name: "huge.iso", size: 6_000_000_000, offset: 5_000_000_000)
        let server = try serve(archive)
        let entries = try await RemoteZipPreview(url: server.url("/a.zip")).listEntries()
        #expect(entries.count == 1)
        #expect(entries.first?.uncompressedSize == 6_000_000_000)
        #expect(entries.first?.localHeaderOffset == 5_000_000_000)
    }

    @Test func t10_01_clearErrors() async throws {
        let notZip = try serve(Data.pattern(count: 5000))
        await #expect(throws: ZipPreviewError.notAZip) { try await RemoteZipPreview(url: notZip.url("/a.zip")).listEntries() }

        let archive = sampleArchive()
        let truncated = try serve(archive.prefix(archive.count - 10) + Data(count: 0))
        await #expect(throws: ZipPreviewError.self) { try await RemoteZipPreview(url: truncated.url("/a.zip")).listEntries() }

        let noRanges = try serve(archive, ranges: false)
        await #expect(throws: ZipPreviewError.rangesNotSupported) { try await RemoteZipPreview(url: noRanges.url("/a.zip")).listEntries() }
    }

    @Test func t10_02_extractsStoredAndDeflatedEntries() async throws {
        let archive = sampleArchive()
        let server = try serve(archive)
        let preview = RemoteZipPreview(url: server.url("/a.zip"))
        let entries = try await preview.listEntries()
        try #require(entries.count == 3)
        let before = requestedBytes(server, total: archive.count)

        let readme = try await preview.extract(entries[1])
        #expect(readme == text)
        #expect(TestZipBuilder.crc32(readme) == entries[1].crc32)
        #expect(requestedBytes(server, total: archive.count) - before < Int(entries[1].compressedSize) + 1000)

        let bigData = try await preview.extract(entries[0])
        #expect(bigData == big)
    }

    @Test func t10_02_unsupportedMethodsAndEncryptionFail() async throws {
        var builder = TestZipBuilder()
        builder.entries = [
            .init(name: "a.bz2", data: Data("x".utf8), method: 12),
            .init(name: "secret.txt", data: Data("y".utf8), method: 0, encrypted: true),
        ]
        let server = try serve(builder.build())
        let preview = RemoteZipPreview(url: server.url("/a.zip"))
        let entries = try await preview.listEntries()
        try #require(entries.count == 2)
        await #expect(throws: ZipPreviewError.unsupportedMethod(12)) { try await preview.extract(entries[0]) }
        await #expect(throws: ZipPreviewError.encrypted) { try await preview.extract(entries[1]) }
    }
}
