import Foundation

/// Registers the cDownloader helper with Chromium browsers so the add-on can reach the app.
public enum NativeHostInstaller {
    /// Browser profile folders below ~/Library/Application Support.
    public static let browserFolders = [
        "Google/Chrome",
        "Google/Chrome Beta",
        "Google/Chrome Canary",
        "Chromium",
        "Microsoft Edge",
        "BraveSoftware/Brave-Browser",
        "Vivaldi",
    ]

    /// Writes the helper manifest into every installed browser; returns the files written.
    @discardableResult
    public static func install(hostExecutable: URL, extensionIDs: [String], applicationSupport: URL) throws -> [URL] {
        let manifest: [String: Any] = [
            "name": AppPaths.nativeHostName,
            "description": "cDownloader browser helper",
            "path": hostExecutable.path,
            "type": "stdio",
            "allowed_origins": extensionIDs.map { "chrome-extension://\($0)/" },
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        var written: [URL] = []
        for folder in browserFolders {
            let browser = applicationSupport.appendingPathComponent(folder, isDirectory: true)
            guard FileManager.default.fileExists(atPath: browser.path) else { continue }
            let file = manifestURL(browser)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            written.append(file)
        }
        return written
    }

    /// Keeps the helper registered, at every launch and on "Reconnect Browsers". It never removes a registration:
    /// the add-on reads the "Take over downloads" switch through the helper, and without the helper it also loses
    /// its right-click items, video button and connection status.
    @discardableResult
    public static func register(hostExecutable: URL?, extensionIDs: [String], applicationSupport: URL) -> [URL] {
        guard let hostExecutable else { return [] }
        return (try? install(hostExecutable: hostExecutable, extensionIDs: extensionIDs, applicationSupport: applicationSupport)) ?? []
    }

    /// Removes the helper manifest from all browsers.
    public static func uninstall(applicationSupport: URL) {
        for folder in browserFolders {
            try? FileManager.default.removeItem(at: manifestURL(applicationSupport.appendingPathComponent(folder, isDirectory: true)))
        }
    }

    /// Browsers that currently have the helper registered.
    public static func installedBrowsers(applicationSupport: URL) -> [String] {
        browserFolders.filter { folder in
            FileManager.default.fileExists(atPath: manifestURL(applicationSupport.appendingPathComponent(folder, isDirectory: true)).path)
        }
    }

    private static func manifestURL(_ browser: URL) -> URL {
        browser.appendingPathComponent("NativeMessagingHosts/\(AppPaths.nativeHostName).json")
    }
}
