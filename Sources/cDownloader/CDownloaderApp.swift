import AppKit
import cDownloaderCore
import SwiftUI

@main
struct CDownloaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("cDownloader", id: "main") {
            MainView()
                .environment(model)
                .onOpenURL { model.handleOpenURL($0) }
                .onAppear {
                    if appDelegate.model == nil { Snapshots.scheduleIfRequested(model: model) }
                    appDelegate.model = model
                }
        }
        .defaultSize(width: 1100, height: 620)
        .commands { AppCommands(model: model) }

        WindowGroup("Download Progress", id: "progress", for: UUID.self) { $id in
            if let id {
                ProgressWindow(itemID: id).environment(model)
            }
        }
        .defaultSize(width: 520, height: 420)
        .windowResizability(.contentSize)

        WindowGroup("Download Complete", id: "complete", for: UUID.self) { $id in
            if let id {
                CompleteWindow(itemID: id).environment(model)
            }
        }
        .windowResizability(.contentSize)

        Window("Scheduler", id: "scheduler") {
            SchedulerView().environment(model)
        }
        .defaultSize(width: 820, height: 560)

        WindowGroup("Site Grabber", id: "grabber", for: UUID.self) { $projectID in
            GrabberWizard(projectID: projectID).environment(model)
        }
        .defaultSize(width: 860, height: 620)

        Window("Drop Target", id: "dropTarget") {
            DropTargetView().environment(model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView().environment(model)
        }

        MenuBarExtra(isInserted: model.setting(\.showMenuBarIcon)) {
            MenuBarContent().environment(model)
        } label: {
            Image(systemName: model.activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.shutdown() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { model?.request(.main) } }
        return true
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    /// Saves links as an IDM-compatible .ef2 file or as plain text, depending on the name chosen.
    @MainActor
    private func export(_ items: [DownloadItem]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "cDownloader links.ef2"
        panel.allowedContentTypes = [.init(filenameExtension: "ef2") ?? .data, .plainText]
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url { model.export(items, to: url) }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add URL…") { model.showAddURL = true }.keyboardShortcut("n")
            Button("Add Batch Download…") { model.showBatch = true }.keyboardShortcut("b", modifiers: [.command, .shift])
            Button("New Site Grabber Project…") { openWindow(id: "grabber", value: UUID()) }.keyboardShortcut("g", modifiers: [.command, .shift])
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Import Links from File…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.plainText, .html, .data]
                if panel.runModal() == .OK, let url = panel.url { model.importLinks(from: url) }
            }
            Menu("Export") {
                Button("Selected Downloads…") { export(model.selectedItems) }.disabled(model.selection.isEmpty)
                Button("All Downloads…") { export(model.library.items) }
                Button("Main Download Queue…") {
                    let ids = model.library.queues.first { $0.id == DownloadQueue.mainDownloadID }?.itemIDs ?? []
                    export(ids.compactMap { model.library.item($0) })
                }
            }
        }
        CommandMenu("Downloads") {
            Button("Resume") { model.selection.forEach { model.library.start($0) } }.keyboardShortcut("r")
            Button("Stop") { model.selection.forEach { model.library.pause($0) } }.keyboardShortcut(".")
            Button("Stop All") { model.library.stopAll() }.keyboardShortcut(".", modifiers: [.command, .shift])
            Divider()
            Button("Start Main Queue") { model.library.startQueue(DownloadQueue.mainDownloadID) }
            Button("Stop Main Queue") { model.library.stopQueue(DownloadQueue.mainDownloadID) }
            Button("Scheduler…") { openWindow(id: "scheduler") }.keyboardShortcut("k")
            Divider()
            Toggle("Speed Limiter", isOn: Binding(get: { model.speedLimiterOn }, set: { model.speedLimiterOn = $0 }))
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Show Drop Target") { openWindow(id: "dropTarget") }
        }
    }
}
