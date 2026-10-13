import AppKit
import cDownloaderCore
import Foundation
import ServiceManagement
import UserNotifications

/// Watches the clipboard and offers copied download links.
@MainActor
final class ClipboardMonitor {
    private var lastChangeCount = NSPasteboard.general.changeCount
    private let filter = ClipboardFilter(extensions: [])

    /// Returns a link to offer when the clipboard changed to a downloadable address.
    func check(extensions: [String]) -> URL? {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return nil }
        lastChangeCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string) else { return nil }
        filter.extensions = extensions
        return filter.offer(text)
    }
}

enum SoundPlayer {
    static func play(_ event: SoundEvent, settings: SoundSettings) {
        guard settings.enabled.contains(event.rawValue), let name = settings.sounds[event.rawValue], !name.isEmpty else { return }
        if name.hasPrefix("/") {
            NSSound(contentsOfFile: name, byReference: true)?.play()
        } else {
            NSSound(named: NSSound.Name(name))?.play()
        }
    }

    static let systemSounds = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]
}

/// macOS notifications; only available when running from the app bundle.
enum Notifier {
    static var available: Bool { !AppPaths.isTestMode && Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// The "when the queue is done" actions.
enum PostActionRunner {
    @MainActor
    static func run(_ action: PostQueueAction) {
        switch action {
        case .none:
            break
        case .quitApp:
            NSApp.terminate(nil)
        case .sleep:
            run("/usr/bin/pmset", ["sleepnow"])
        case .shutDown(let force):
            let script = force
                ? "tell application \"System Events\" to shut down"
                : "tell application \"Finder\" to shut down"
            run("/usr/bin/osascript", ["-e", script])
        case .openFile(let path):
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    static func run(_ tool: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try? process.run()
    }
}

/// Runs the user's virus scanner on a finished file.
enum ScanRunner {
    static func scan(_ file: URL, settings: ScanSettings) {
        guard settings.enabled, !settings.executablePath.isEmpty else { return }
        var arguments = settings.arguments.split(separator: " ").map(String.init)
        if arguments.contains("%f") {
            arguments = arguments.map { $0 == "%f" ? file.path : $0 }
        } else {
            arguments.append(file.path)
        }
        PostActionRunner.run(settings.executablePath, arguments)
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        guard !AppPaths.isTestMode else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("cDownloader: launch at login change failed: \(error.localizedDescription)")
        }
    }
}

/// Registers the browser helper and finds the bundled add-on folder.
enum BrowserIntegration {
    static var hostExecutable: URL? {
        let candidate = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cDownloaderHost")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    static var extensionFolder: URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Extension", isDirectory: true)
        return FileManager.default.fileExists(atPath: bundled.path) ? bundled : nil
    }

    static var extensionID: String {
        guard let folder = extensionFolder,
              let data = try? Data(contentsOf: folder.appendingPathComponent("extension-id.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let id = json["extensionId"]
        else { return "gddglpejfoibglhchibiacdnahmmabkk" }
        return id
    }

    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Registers the helper whatever "Take over downloads" is set to; the add-on reads that switch through the helper.
    static func register() {
        guard !AppPaths.isTestMode else { return }
        NativeHostInstaller.register(hostExecutable: hostExecutable, extensionIDs: [extensionID], applicationSupport: applicationSupport)
    }

    static var installedBrowsers: [String] {
        NativeHostInstaller.installedBrowsers(applicationSupport: applicationSupport).map { $0.components(separatedBy: "/").last ?? $0 }
    }
}

enum Format {
    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? ""
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func status(_ item: DownloadItem, progress: DownloadProgressSnapshot?) -> String {
        switch item.status {
        case .completed: return String(localized: "Complete")
        case .failed: return String(localized: "Error")
        case .waiting: return String(localized: "Waiting")
        case .downloading:
            if let total = progress?.totalBytes ?? item.totalBytes, total > 0 {
                let done = progress?.downloadedBytes ?? item.downloadedBytes
                return String(format: "%.1f%%", Double(done) * 100 / Double(total))
            }
            return String(localized: "Downloading")
        case .stopped:
            if let total = item.totalBytes, total > 0, item.downloadedBytes > 0 {
                return String(format: "%.1f%%", Double(item.downloadedBytes) * 100 / Double(total))
            }
            return ""
        }
    }
}
