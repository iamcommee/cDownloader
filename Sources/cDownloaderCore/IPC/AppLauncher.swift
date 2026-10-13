import Foundation

public enum AppPaths {
    public static let bundleIdentifier = "com.cdownloader.app"
    public static let nativeHostName = "com.cdownloader.host"

    /// Test mode (CDOWNLOADER_TEST_MODE=1) skips browser registration, notification prompts and login items.
    public static var isTestMode: Bool { ProcessInfo.processInfo.environment["CDOWNLOADER_TEST_MODE"] == "1" }

    /// ~/Library/Application Support/cDownloader, or CDOWNLOADER_SUPPORT_DIR when set (for test runs).
    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CDOWNLOADER_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("cDownloader", isDirectory: true)
    }

    /// The app's socket. macOS limits socket paths to 103 bytes, so very long home folders fall back to /tmp.
    public static var socketPath: String { socketPath(for: supportDirectory) }

    public static func socketPath(for supportDirectory: URL) -> String {
        let preferred = supportDirectory.appendingPathComponent("ipc.sock").path
        if preferred.utf8.count < 104 { return preferred }
        // The per-user temporary folder is private to this user, unlike /tmp.
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cdownloader.sock").path
    }
    public static var settingsFile: URL { supportDirectory.appendingPathComponent("settings.json") }
    public static var libraryFile: URL { supportDirectory.appendingPathComponent("library.json") }
    public static var grabberProjectsFile: URL { supportDirectory.appendingPathComponent("grabber-projects.json") }
    public static var temporaryDirectory: URL { supportDirectory.appendingPathComponent("Temp", isDirectory: true) }
    /// The app's own copy of yt-dlp, which it keeps up to date.
    public static var toolsDirectory: URL { supportDirectory.appendingPathComponent("Tools", isDirectory: true) }
    /// The tools packed inside the app (yt-dlp, deno, ffmpeg); nil when not running from an app, as in tests.
    public static var bundledToolsDirectory: URL? {
        appBundle?.appendingPathComponent("Contents/Helpers", isDirectory: true)
    }
    /// The packed yt-dlp's version. It lives with the resources, since the programs folder may hold only programs.
    public static var bundledYtDlpVersionFile: URL? {
        appBundle?.appendingPathComponent("Contents/Resources/yt-dlp.version")
    }
    private static var appBundle: URL? {
        let bundle = Bundle.main.bundleURL
        return bundle.pathExtension == "app" ? bundle : nil
    }
}

/// Used by the command-line tool and the browser helper to reach the app, opening it when needed.
public enum AppLauncher {
    public static func send(_ request: IPCRequest, socketPath: String = AppPaths.socketPath, launchIfNeeded: Bool = true, waitSeconds: TimeInterval = 15) throws -> IPCReply {
        do {
            return try IPCClient.send(request, socketPath: socketPath)
        } catch IPCError.appNotRunning where launchIfNeeded {
            launchInBackground()
            let deadline = Date().addingTimeInterval(waitSeconds)
            while Date() < deadline {
                usleep(250_000)
                if let reply = try? IPCClient.send(request, socketPath: socketPath) { return reply }
            }
            throw IPCError.appNotRunning
        }
    }

    /// Opens cDownloader without bringing it to the front.
    public static func launchInBackground() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-b", AppPaths.bundleIdentifier]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
