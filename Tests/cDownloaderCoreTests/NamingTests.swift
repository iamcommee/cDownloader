import Foundation
import Testing
@testable import cDownloaderCore

@Suite struct NamingTests {
    struct NameRow: Sendable, CustomTestStringConvertible {
        var label: String
        var disposition: String?
        var url: String
        var mime: String?
        var expected: String
        var testDescription: String { label }
    }

    @Test(arguments: [
        NameRow(label: "CD plain", disposition: "attachment; filename=\"a b.zip\"", url: "https://h/x", mime: nil, expected: "a b.zip"),
        NameRow(label: "CD unquoted", disposition: "attachment; filename=report.pdf", url: "https://h/x", mime: nil, expected: "report.pdf"),
        NameRow(label: "CD 5987", disposition: "attachment; filename*=UTF-8''%E2%82%AC.txt", url: "https://h/x", mime: nil, expected: "€.txt"),
        NameRow(label: "both", disposition: "attachment; filename=\"plain.txt\"; filename*=UTF-8''fancy%20name.txt", url: "https://h/x", mime: nil, expected: "fancy name.txt"),
        NameRow(label: "URL last", disposition: nil, url: "https://h/x/y%20z.pdf", mime: nil, expected: "y z.pdf"),
        NameRow(label: "query", disposition: nil, url: "https://h/f.zip?a=1", mime: nil, expected: "f.zip"),
        NameRow(label: "empty path", disposition: nil, url: "https://h/", mime: nil, expected: "download"),
        NameRow(label: "MIME ext", disposition: nil, url: "https://h/file", mime: "image/png", expected: "file.png"),
        NameRow(label: "MIME with params", disposition: nil, url: "https://h/file", mime: "application/pdf; charset=binary", expected: "file.pdf"),
        NameRow(label: "has ext", disposition: nil, url: "https://h/a.zip", mime: "text/html", expected: "a.zip"),
        NameRow(label: "traversal", disposition: "attachment; filename=\"../../etc/passwd\"", url: "https://h/x", mime: nil, expected: "passwd"),
        NameRow(label: "colon", disposition: "attachment; filename=\"a:b.txt\"", url: "https://h/x", mime: nil, expected: "a-b.txt"),
    ])
    func t3_01_resolvesFileName(row: NameRow) {
        let name = FileNameResolver.fileName(contentDisposition: row.disposition, url: URL(string: row.url)!, mimeType: row.mime)
        #expect(name == row.expected)
    }

    @Test func t3_02_collisionAddsNextFreeNumber() {
        let dir = URL(fileURLWithPath: "/tmp/dl")
        let taken: Set<String> = ["a.zip", "a (1).zip"]
        let result = FileNameResolver.uniqueURL(for: dir.appendingPathComponent("a.zip")) { taken.contains($0.lastPathComponent) }
        #expect(result.lastPathComponent == "a (2).zip")
        let free = FileNameResolver.uniqueURL(for: dir.appendingPathComponent("b.zip")) { taken.contains($0.lastPathComponent) }
        #expect(free.lastPathComponent == "b.zip")
        let noExt = FileNameResolver.uniqueURL(for: dir.appendingPathComponent("README")) { $0.lastPathComponent == "README" }
        #expect(noExt.lastPathComponent == "README (1)")
    }

    struct WildcardRow: Sendable, CustomTestStringConvertible {
        var label: String
        var pattern: String
        var text: String
        var match: Bool
        var testDescription: String { label }
    }

    @Test(arguments: [
        WildcardRow(label: "mid", pattern: "*.example.com", text: "cdn.EXAMPLE.com", match: true),
        WildcardRow(label: "none", pattern: "*.example.com", text: "example.org", match: false),
        WildcardRow(label: "literal dot", pattern: "a.c", text: "abc", match: false),
        WildcardRow(label: "all", pattern: "*", text: "anything", match: true),
        WildcardRow(label: "empty text", pattern: "*", text: "", match: true),
        WildcardRow(label: "regex chars", pattern: "a+b(*)", text: "a+b(x)", match: true),
        WildcardRow(label: "star middle", pattern: "img*.jpg", text: "img042.jpg", match: true),
        WildcardRow(label: "empty pattern", pattern: "", text: "x", match: false),
    ])
    func t3_03_wildcard(row: WildcardRow) {
        #expect(Wildcard.matches(row.pattern, row.text) == row.match)
    }

    @Test func t3_04_siteLoginsUseLongestPrefixAndDownloadCredentialsWin() {
        let secrets = InMemorySecretStore()
        let root = SiteLogin(urlPrefix: "http://h/", username: "root")
        let privateArea = SiteLogin(urlPrefix: "http://h/private/", username: "priv")
        secrets.setPassword("rootpw", for: root.credentialKey)
        secrets.setPassword("privpw", for: privateArea.credentialKey)
        let logins = [root, privateArea]

        #expect(SiteLoginResolver.login(for: URL(string: "http://h/private/x")!, in: logins)?.username == "priv")
        #expect(SiteLoginResolver.login(for: URL(string: "http://h/pub")!, in: logins)?.username == "root")
        #expect(SiteLoginResolver.login(for: URL(string: "http://other/x")!, in: logins) == nil)

        var item = DownloadItem(url: URL(string: "http://h/private/x")!, fileName: "x", directory: "/tmp")
        let fromList = SiteLoginResolver.credentials(for: item, logins: logins, secrets: secrets)
        #expect(fromList?.user == "priv" && fromList?.password == "privpw")
        item.username = "own"
        secrets.setPassword("ownpw", for: item.credentialKey)
        let own = SiteLoginResolver.credentials(for: item, logins: logins, secrets: secrets)
        #expect(own?.user == "own" && own?.password == "ownpw")
    }

    @Test func t3_05_connectionExceptionsFirstMatchWins() {
        let exceptions = [
            ConnectionException(hostPattern: "*.slow.com", maxConnections: 1),
            ConnectionException(hostPattern: "a.slow.com", maxConnections: 3),
        ]
        #expect(ConnectionLimits.maxConnections(forHost: "a.slow.com", exceptions: exceptions, defaultValue: 8) == 1)
        #expect(ConnectionLimits.maxConnections(forHost: "fast.com", exceptions: exceptions, defaultValue: 8) == 8)
    }

    @Test func t3_06_proxySettingsMapToSessionDictionary() {
        var settings = ProxySettings()
        #expect(ProxyConfigurator.connectionProxyDictionary(for: settings) == nil)

        settings.mode = .none
        #expect(ProxyConfigurator.connectionProxyDictionary(for: settings)?.isEmpty == true)

        settings.mode = .manual
        settings.httpHost = "proxy.local"
        settings.httpPort = 3128
        settings.socksHost = "socks.local"
        settings.socksPort = 1081
        settings.bypass = ["*.internal"]
        let dict = ProxyConfigurator.connectionProxyDictionary(for: settings) ?? [:]
        #expect(dict[kCFNetworkProxiesHTTPProxy as String] as? String == "proxy.local")
        #expect(dict[kCFNetworkProxiesHTTPPort as String] as? Int == 3128)
        #expect(dict[kCFNetworkProxiesHTTPSProxy as String] as? String == "proxy.local")
        #expect(dict[kCFNetworkProxiesSOCKSProxy as String] as? String == "socks.local")
        #expect(dict[kCFNetworkProxiesSOCKSPort as String] as? Int == 1081)
        #expect(dict[kCFNetworkProxiesExceptionsList as String] as? [String] == ["*.internal"])
    }
}
