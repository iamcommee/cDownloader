import Foundation
import Testing
@testable import cDownloaderCore

@Suite struct InputTests {
    struct BatchRow: Sendable, CustomTestStringConvertible {
        var label: String
        var template: String
        var range: BatchPattern.Range
        var expected: [String]?
        var error: BatchPattern.BatchError?
        var testDescription: String { label }
    }

    @Test(arguments: [
        BatchRow(label: "num", template: "https://h/a*.jpg", range: .numbers(from: 1, to: 3, width: 0), expected: ["https://h/a1.jpg", "https://h/a2.jpg", "https://h/a3.jpg"]),
        BatchRow(label: "pad", template: "https://h/a*.jpg", range: .numbers(from: 1, to: 3, width: 3), expected: ["https://h/a001.jpg", "https://h/a002.jpg", "https://h/a003.jpg"]),
        BatchRow(label: "pad overflow", template: "https://h/*.jpg", range: .numbers(from: 8, to: 11, width: 2), expected: ["https://h/08.jpg", "https://h/09.jpg", "https://h/10.jpg", "https://h/11.jpg"]),
        BatchRow(label: "narrow width", template: "https://h/*.jpg", range: .numbers(from: 99, to: 100, width: 2), expected: ["https://h/99.jpg", "https://h/100.jpg"]),
        BatchRow(label: "letters", template: "https://h/x*.txt", range: .letters(from: "a", to: "c"), expected: ["https://h/xa.txt", "https://h/xb.txt", "https://h/xc.txt"]),
        BatchRow(label: "one", template: "https://h/p*.png", range: .numbers(from: 5, to: 5, width: 0), expected: ["https://h/p5.png"]),
        BatchRow(label: "reversed", template: "https://h/a*.jpg", range: .numbers(from: 3, to: 1, width: 0), error: .reversedRange),
        BatchRow(label: "reversed letters", template: "https://h/a*.jpg", range: .letters(from: "z", to: "a"), error: .reversedRange),
        BatchRow(label: "no star", template: "https://h/a.jpg", range: .numbers(from: 1, to: 2, width: 0), error: .noWildcard),
        BatchRow(label: "multiple stars", template: "https://h/a*b*.jpg", range: .numbers(from: 1, to: 2, width: 0), error: .multipleWildcards),
    ])
    func t9_01_batchTemplateExpansion(row: BatchRow) {
        if let expected = row.expected {
            #expect((try? BatchPattern.expand(row.template, range: row.range).map(\.absoluteString)) == expected)
        } else {
            #expect(throws: row.error!) { try BatchPattern.expand(row.template, range: row.range) }
        }
    }

    @Test func t9_02_extractsLinksFromProse() {
        let text = """
        Grab https://example.com/a.zip, then (see http://example.com/b.pdf).
        Mirror: ftp://files.example.com/pub/c.iso. Again https://example.com/a.zip!
        Not these: mailto:x@y.z file:///etc/hosts www.nope.com
        Wiki https://en.wikipedia.org/wiki/Foo_(bar) end
        """
        #expect(LinkImporter.extractURLs(from: text).map(\.absoluteString) == [
            "https://example.com/a.zip",
            "http://example.com/b.pdf",
            "ftp://files.example.com/pub/c.iso",
            "https://en.wikipedia.org/wiki/Foo_(bar)",
        ])
        #expect(LinkImporter.extractURLs(from: "no links here").isEmpty)
    }

    @Test func t9_03_ef2RoundTripWithExactBytes() throws {
        let entries = [
            EF2Entry(url: URL(string: "https://h/a.zip")!, referer: "https://h/page", userAgent: "UA/1", cookie: "s=1"),
            EF2Entry(url: URL(string: "https://h/b.zip")!),
        ]
        let data = EF2Codec.encode(entries)
        let expectedFirstBlock = "<\r\nhttps://h/a.zip\r\nreferer: https://h/page\r\nUser-Agent: UA/1\r\ncookie: s=1\r\n>\r\n"
        #expect(String(decoding: data, as: UTF8.self).hasPrefix(expectedFirstBlock))
        #expect(EF2Codec.decode(data) == entries)
    }

    @Test func t9_03_ef2ImportIsTolerant() {
        let lfOnly = Data("<\nhttps://h/c.zip\nReferer: https://h/\n>\n<\nhttps://h/d.zip\n>\n".utf8)
        #expect(EF2Codec.decode(lfOnly) == [
            EF2Entry(url: URL(string: "https://h/c.zip")!, referer: "https://h/"),
            EF2Entry(url: URL(string: "https://h/d.zip")!),
        ])
        #expect(EF2Codec.decode(Data([0xFF, 0x00, 0x3C, 0x0A])) == [])
        #expect(EF2Codec.decode(Data("<\n\n>\n<\nnot a url\n>".utf8)) == [])
    }

    @Test func t9_03_plainTextImportAndExport() {
        let urls = LinkImporter.importPlainText("https://h/a.zip\n\n  https://h/b.zip  \nnot a url\nftp://h/c.iso\n")
        #expect(urls.map(\.absoluteString) == ["https://h/a.zip", "https://h/b.zip", "ftp://h/c.iso"])
        #expect(LinkImporter.exportPlainText(urls) == "https://h/a.zip\nhttps://h/b.zip\nftp://h/c.iso\n")
    }

    struct ClipRow: Sendable, CustomTestStringConvertible {
        var label: String
        var text: String
        var offered: String?
        var testDescription: String { label }
    }

    @Test(arguments: [
        ClipRow(label: "url match", text: "https://h/a.ZIP", offered: "https://h/a.ZIP"),
        ClipRow(label: "not listed", text: "https://h/a.html", offered: nil),
        ClipRow(label: "two URLs", text: "https://h/a.zip\nhttps://h/b.zip", offered: nil),
        ClipRow(label: "not URL", text: "hello.zip", offered: nil),
        ClipRow(label: "whitespace", text: "\n  https://h/a.pdf \n", offered: "https://h/a.pdf"),
        ClipRow(label: "query", text: "https://h/a.zip?x=1", offered: "https://h/a.zip?x=1"),
        ClipRow(label: "ftp", text: "ftp://h/a.mp4", offered: "ftp://h/a.mp4"),
        ClipRow(label: "other scheme", text: "file:///tmp/a.zip", offered: nil),
    ])
    func t9_04_clipboardFilter(row: ClipRow) {
        let filter = ClipboardFilter(extensions: ["pdf", "zip", "mp4"])
        #expect(filter.offer(row.text)?.absoluteString == row.offered)
    }

    @Test func t9_04_sameTextIsOfferedOnceUntilClipboardChanges() {
        let filter = ClipboardFilter(extensions: ["zip"])
        #expect(filter.offer("https://h/a.zip") != nil)
        #expect(filter.offer("https://h/a.zip") == nil)
        #expect(filter.offer("something else") == nil)
        #expect(filter.offer("https://h/a.zip") != nil)
    }
}
