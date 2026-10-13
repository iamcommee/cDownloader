import AppKit
import cDownloaderCore
import SwiftUI

/// Test-mode helper: with CDOWNLOADER_SNAPSHOT_DIR set, saves a PNG of every open window a few seconds
/// after launch (and opens the windows listed in CDOWNLOADER_SNAPSHOT_OPEN first), so the layout can be
/// checked without screen-recording permission.
@MainActor
enum Snapshots {
    private static var settingsWindow: NSWindow?

    static func scheduleIfRequested(model: AppModel) {
        let environment = ProcessInfo.processInfo.environment
        guard AppPaths.isTestMode, let folder = environment["CDOWNLOADER_SNAPSHOT_DIR"] else { return }
        let toOpen = (environment["CDOWNLOADER_SNAPSHOT_OPEN"] ?? "").split(separator: ",").map(String.init)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            for name in toOpen {
                switch name {
                case "settings":
                    let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView().environment(model)))
                    window.title = "Settings"
                    window.makeKeyAndOrderFront(nil)
                    settingsWindow = window
                case "videoSites":
                    let window = NSWindow(contentViewController: NSHostingController(rootView: VideoSiteSettings().environment(model).frame(width: 560, height: 420)))
                    window.title = "Video Sites"
                    window.makeKeyAndOrderFront(nil)
                    settingsWindow = window
                case "webVideoInfo":
                    model.pendingInfo = model.library.makeItem(from: IncomingDownload(url: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!), folder: nil)
                case "scheduler": model.request(.scheduler)
                case "grabber": model.request(.grabber(nil))
                case "add": model.showAddURL = true
                case "batch": model.showBatch = true
                case "dropTarget": model.request(.dropTarget)
                default:
                    if name.hasPrefix("progress"), let first = model.library.items.first { model.selection = [first.id] }
                    if name.hasPrefix("complete"), let first = model.library.items.first { model.showCompletionBanner(for: first.id) }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            capture(to: URL(fileURLWithPath: folder, isDirectory: true))
        }
    }

    static func capture(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView, view.bounds.width > 50 else { continue }
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let name = window.title.isEmpty ? "window-\(index)" : window.title.replacingOccurrences(of: "/", with: "-")
            try? bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
        }
    }
}
