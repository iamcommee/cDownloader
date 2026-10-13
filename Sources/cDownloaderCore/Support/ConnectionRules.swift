import Foundation

public enum SiteLoginResolver {
    /// The saved login whose URL prefix is the longest match for `url`.
    public static func login(for url: URL, in logins: [SiteLogin]) -> SiteLogin? {
        let address = url.absoluteString.lowercased()
        return logins
            .filter { !$0.urlPrefix.isEmpty && address.hasPrefix($0.urlPrefix.lowercased()) }
            .max { $0.urlPrefix.count < $1.urlPrefix.count }
    }

    /// Per-download credentials win; otherwise the best Site Logins entry.
    public static func credentials(for item: DownloadItem, logins: [SiteLogin], secrets: SecretStore) -> (user: String, password: String)? {
        if let user = item.username, !user.isEmpty {
            return (user, secrets.password(for: item.credentialKey) ?? "")
        }
        guard let login = login(for: item.finalURL ?? item.url, in: logins) else { return nil }
        return (login.username, secrets.password(for: login.credentialKey) ?? "")
    }
}

extension URL {
    /// Whether cookies and logins captured for `self` may be sent to `other`.
    /// Same host and same scheme and port, or the same host upgraded from http to https.
    /// A downgrade to http or any other host never shares them.
    public func sharesCredentials(with other: URL) -> Bool {
        guard let host = host?.lowercased(), host == other.host?.lowercased() else { return false }
        let from = scheme?.lowercased() ?? ""
        let to = other.scheme?.lowercased() ?? ""
        func port(_ url: URL, _ scheme: String) -> Int { url.port ?? (scheme == "https" ? 443 : scheme == "ftp" ? 21 : 80) }
        if from == to { return port(self, from) == port(other, to) }
        return from == "http" && to == "https" && port(self, from) == 80 && port(other, to) == 443
    }

    /// Scheme, host and port: cookies and logins are only sent where they came from.
    public var origin: String {
        let scheme = self.scheme?.lowercased() ?? ""
        let port = self.port ?? (scheme == "https" ? 443 : scheme == "ftp" ? 21 : 80)
        return "\(scheme)://\((host ?? "").lowercased()):\(port)"
    }
}

public enum ConnectionLimits {
    /// The first matching host exception, else the global default.
    public static func maxConnections(forHost host: String, exceptions: [ConnectionException], defaultValue: Int) -> Int {
        let rule = exceptions.first { Wildcard.matches($0.hostPattern, host) }
        return max(1, rule?.maxConnections ?? defaultValue)
    }
}

public enum ProxyConfigurator {
    /// Dictionary for `URLSessionConfiguration.connectionProxyDictionary`.
    /// nil means "use the system settings"; an empty dictionary means "no proxy".
    public static func connectionProxyDictionary(for settings: ProxySettings) -> [AnyHashable: Any]? {
        switch settings.mode {
        case .system:
            return nil
        case .none:
            return [:]
        case .manual:
            var dict: [AnyHashable: Any] = [:]
            if !settings.httpHost.isEmpty {
                dict[kCFNetworkProxiesHTTPEnable as String] = 1
                dict[kCFNetworkProxiesHTTPProxy as String] = settings.httpHost
                dict[kCFNetworkProxiesHTTPPort as String] = settings.httpPort
            }
            let httpsHost = settings.sameProxyForHTTPS ? settings.httpHost : settings.httpsHost
            let httpsPort = settings.sameProxyForHTTPS ? settings.httpPort : settings.httpsPort
            if !httpsHost.isEmpty {
                dict[kCFNetworkProxiesHTTPSEnable as String] = 1
                dict[kCFNetworkProxiesHTTPSProxy as String] = httpsHost
                dict[kCFNetworkProxiesHTTPSPort as String] = httpsPort
            }
            if !settings.socksHost.isEmpty {
                dict[kCFNetworkProxiesSOCKSEnable as String] = 1
                dict[kCFNetworkProxiesSOCKSProxy as String] = settings.socksHost
                dict[kCFNetworkProxiesSOCKSPort as String] = settings.socksPort
            }
            if !settings.bypass.isEmpty {
                dict[kCFNetworkProxiesExceptionsList as String] = settings.bypass
            }
            return dict
        }
    }
}
