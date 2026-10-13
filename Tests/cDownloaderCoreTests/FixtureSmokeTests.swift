import Foundation
import Testing

@Suite struct FixtureSmokeTests {
    @Test func t1_httpServerServesRanges() async throws {
        let server = try LocalHTTPServer()
        let body = Data.pattern(count: 1000)
        server.set("/f.bin", .init(body: body))
        var request = URLRequest(url: server.url("/f.bin"))
        request.setValue("bytes=100-", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 206)
        #expect(data == body.subdata(in: 100..<1000))
    }
}
