import cDownloaderCore
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var confirmDelete = false
    @AppStorage("showDetailsPanel") private var showDetailsPanel = true

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            VStack(spacing: 0) {
                DownloadTable()
                if showDetailsPanel {
                    Divider()
                    DownloadDetailsPanel()
                }
            }
            .overlay(alignment: .top) {
                if let id = model.completionBanner, let item = model.library.item(id) {
                    CompletionBanner(item: item)
                        .padding(.top, 10)
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: model.completionBanner)
        }
        .background(SidebarDividerFix())
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search downloads")
        .toolbar { toolbar }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDroppedURLs(urls)
            return true
        }
        .sheet(isPresented: $model.showAddURL) { AddURLSheet(prefill: model.addURLPrefill) }
        .sheet(item: $model.pendingInfo) { item in DownloadInfoSheet(item: item) }
        .sheet(item: Binding(
            get: { model.pendingSelection.map { SelectionBox(items: $0) } },
            set: { model.pendingSelection = $0?.items }
        )) { box in SelectLinksSheet(items: box.items) }
        .sheet(isPresented: $model.showBatch) { BatchDownloadSheet() }
        .sheet(item: $model.zipPreviewItem) { item in ZipPreviewSheet(item: item) }
        .sheet(item: $model.propertiesItem) { item in PropertiesSheet(item: item) }
        .confirmationDialog("Delete the selected downloads?", isPresented: $confirmDelete) {
            Button("Remove from List") { model.library.remove(model.selection, deleteFiles: false); model.selection = [] }
            Button("Remove and Move Files to Trash", role: .destructive) { model.library.remove(model.selection, deleteFiles: true); model.selection = [] }
        } message: {
            Text("Unfinished downloads lose their partial data.")
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onChange(of: model.windowRequests) { _, _ in openPendingWindows() }
        .onAppear { openPendingWindows() }
    }

    private func openPendingWindows() {
        let requests = model.windowRequests
        guard !requests.isEmpty else { return }
        model.windowRequests = []
        for request in requests where request != .main { open(request) }
    }

    private func open(_ request: WindowRequest) {
        switch request {
        case .main: openWindow(id: "main")
        case .scheduler: openWindow(id: "scheduler")
        case .grabber(let id): openWindow(id: "grabber", value: id ?? UUID())
        case .dropTarget: openWindow(id: "dropTarget")
        }
    }

    private var title: String {
        switch model.sidebarSelection {
        case .all: String(localized: "All Downloads")
        case .unfinished: String(localized: "Unfinished")
        case .finished: String(localized: "Finished")
        case .category(let id): model.library.categories.first { $0.id == id }?.name ?? "cDownloader"
        case .queue(let id): model.library.queues.first { $0.id == id }?.name ?? "cDownloader"
        case .grabberProject(let id): model.grabberProjects.first { $0.id == id }?.name ?? "cDownloader"
        }
    }

    private var subtitle: String {
        let speed = Format.speed(model.totalSpeed)
        let count = model.visibleItems.count
        let files = count == 1 ? String(localized: "1 file") : String(localized: "\(count) files")
        return speed.isEmpty ? files : "\(files) · \(speed)"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.addURLPrefill = ""; model.showAddURL = true } label: { Label("Add URL", systemImage: "plus") }
                .help("Add a download address")
            Button { model.selection.forEach { model.library.start($0) } } label: { Label("Resume", systemImage: "play.fill") }
                .help("Start or resume the selected downloads")
                .disabled(!model.selectedItems.contains { $0.status != .completed && $0.status != .downloading })
            Button { model.selection.forEach { model.library.pause($0) } } label: { Label("Stop", systemImage: "pause.fill") }
                .help("Stop the selected downloads")
                .disabled(!model.selectedItems.contains { $0.status == .downloading || $0.status == .waiting })
            Button { model.library.stopAll() } label: { Label("Stop All", systemImage: "stop.fill") }
                .help("Stop every running download and queue")
            Button { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                .help("Delete the selected downloads")
                .disabled(model.selection.isEmpty)
            Button { model.library.removeCompleted() } label: { Label("Delete Completed", systemImage: "checkmark.circle.badge.xmark") }
                .help("Remove all finished downloads from the list (files stay)")
            Button { showDetailsPanel.toggle() } label: {
                Label(showDetailsPanel ? "Hide Details" : "Show Details", systemImage: "rectangle.bottomthird.inset.filled")
            }
            .help("Show or hide the selected download's progress under the list")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                ForEach(model.library.queues) { queue in
                    Button(queue.name) { model.library.startQueue(queue.id) }
                }
            } label: { Label("Start Queue", systemImage: "list.bullet.circle") } primaryAction: {
                model.library.startQueue(DownloadQueue.mainDownloadID)
            }
            .help("Start the main download queue (click the arrow for other queues)")
            Menu {
                ForEach(model.library.queues) { queue in
                    Button(queue.name) { model.library.stopQueue(queue.id) }
                }
            } label: { Label("Stop Queue", systemImage: "list.bullet.circle.fill") } primaryAction: {
                model.library.stopQueue(DownloadQueue.mainDownloadID)
            }
            .help("Stop the main download queue")
            Button { openWindow(id: "scheduler") } label: { Label("Scheduler", systemImage: "calendar.badge.clock") }
                .help("Schedule queues")
            Button { openWindow(id: "grabber", value: UUID()) } label: { Label("Grabber", systemImage: "globe") }
                .help("Download files from a whole web site")
            Toggle(isOn: Binding(get: { model.speedLimiterOn }, set: { model.speedLimiterOn = $0 })) {
                Label("Speed Limiter", systemImage: "gauge.with.dots.needle.33percent")
            }
            .help("Limit the total download speed")
            Button { openSettings() } label: { Label("Options", systemImage: "gearshape") }
                .help("cDownloader settings")
        }
    }
}

/// Lets an array drive a `.sheet(item:)`.
struct SelectionBox: Identifiable {
    let id = UUID()
    let items: [DownloadItem]
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var editingCategory: DownloadCategory?
    @State private var renamingQueue: DownloadQueue?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebarSelection) {
            Section("Downloads") {
                Label("All Downloads", systemImage: "tray.full").tag(SidebarItem.all)
                Label("Unfinished", systemImage: "arrow.down.circle").tag(SidebarItem.unfinished)
                Label("Finished", systemImage: "checkmark.circle").tag(SidebarItem.finished)
            }
            Section("Categories") {
                ForEach(model.library.categories) { category in
                    Label(category.name, systemImage: icon(for: category))
                        .tag(SidebarItem.category(category.id))
                        .contextMenu {
                            Button("Edit Category…") { editingCategory = category }
                            Button("Open Folder") { NSWorkspace.shared.open(URL(fileURLWithPath: category.folder)) }
                            if category.id != DownloadCategory.generalID {
                                Button("Delete Category", role: .destructive) { model.library.deleteCategory(category.id) }
                            }
                        }
                }
                Button { editingCategory = DownloadCategory(name: "", extensions: [], folder: model.library.categories.first?.folder ?? NSHomeDirectory()) } label: {
                    Label("Add Category…", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Section("Queues") {
                ForEach(model.library.queues) { queue in
                    HStack {
                        Label(queue.name, systemImage: queue.kind == .download ? "square.stack.3d.down.forward" : "arrow.triangle.2.circlepath")
                        Spacer()
                        if model.library.isQueueRunning(queue.id) {
                            Image(systemName: "play.circle.fill").foregroundStyle(.green).help("Running")
                        } else if queue.schedule.startEnabled {
                            Image(systemName: "clock").foregroundStyle(.secondary).help("Scheduled")
                        }
                        Text("\(queue.itemIDs.count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .tag(SidebarItem.queue(queue.id))
                    .dropDestination(for: String.self) { values, _ in
                        let ids = values.compactMap(UUID.init(uuidString:))
                        model.library.moveItems(ids, toQueue: queue.id)
                        return !ids.isEmpty
                    }
                    .contextMenu {
                        Button("Start") { model.library.startQueue(queue.id) }
                        Button("Stop") { model.library.stopQueue(queue.id) }
                        Button("Edit Queue and Schedule…") { openWindow(id: "scheduler") }
                        Button("Rename…") { renamingQueue = queue }
                        if !queue.isMain {
                            Button("Delete Queue", role: .destructive) { model.library.deleteQueue(queue.id) }
                        }
                    }
                }
                Button { model.library.addQueue(name: String(localized: "New Queue"), kind: .download) } label: {
                    Label("New Queue", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            if !model.grabberProjects.isEmpty {
                Section("Grabber Projects") {
                    ForEach(model.grabberProjects) { project in
                        Label(project.name, systemImage: "globe")
                            .tag(SidebarItem.grabberProject(project.id))
                            .contextMenu {
                                Button("Open Project…") { openWindow(id: "grabber", value: project.id) }
                                Button("Run Again and Download") { model.runGrabber(project, thenDownload: true) }
                                Button("Delete Project", role: .destructive) { model.deleteGrabberProject(project.id) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .sheet(item: $editingCategory) { category in CategoryEditor(category: category) }
        .sheet(item: $renamingQueue) { queue in RenameQueueSheet(queue: queue) }
    }

    private func icon(for category: DownloadCategory) -> String {
        switch category.id {
        case "compressed": "doc.zipper"
        case "documents": "doc.text"
        case "music": "music.note"
        case "programs": "app.badge"
        case "video": "film"
        case DownloadCategory.generalID: "folder"
        default: "folder.badge.gearshape"
        }
    }
}

struct CategoryEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var category: DownloadCategory
    @State private var extensionsText = ""

    var body: some View {
        Form {
            TextField("Name", text: $category.name)
            TextField("File types (separated by spaces)", text: $extensionsText, prompt: Text("zip rar 7z"))
            HStack {
                TextField("Save to", text: $category.folder)
                Button("Choose…") {
                    if let folder = FolderPicker.choose(start: category.folder) { category.folder = folder }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { extensionsText = category.extensions.joined(separator: " ") }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    category.extensions = extensionsText.lowercased().split(whereSeparator: { $0 == " " || $0 == "," }).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
                    if model.library.categories.contains(where: { $0.id == category.id }) {
                        model.library.updateCategory(category)
                    } else {
                        model.library.addCategory(category)
                    }
                    dismiss()
                }
                .disabled(category.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

struct RenameQueueSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var queue: DownloadQueue

    var body: some View {
        Form {
            TextField("Queue name", text: $queue.name)
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Rename") { model.library.updateQueue(queue); dismiss() }
            }
        }
    }
}

enum FolderPicker {
    @MainActor
    static func choose(start: String?) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let start { panel.directoryURL = URL(fileURLWithPath: start, isDirectory: true) }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    @MainActor
    static func chooseFile(types: [UTType] = []) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if !types.isEmpty { panel.allowedContentTypes = types }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// The line between the sidebar and the list is a one-point strip that shows what is behind the window, stacked over
/// the list's edge. When the closed window reopens and the app comes to the front, macOS can draw that strip one
/// pixel too wide for a frame or two, which flashes a see-through line down the list's edge. Blending the strip within
/// the window removes the flash; the sidebar itself keeps showing what is behind the window.
@MainActor
enum SidebarDivider {
    /// Switches the see-through parts of every side-by-side split view's dividers under `root`; columns stay as they are.
    static func blendWithinWindow(in root: NSView) {
        if let split = root as? NSSplitView, split.isVertical {
            for part in split.subviews where !split.arrangedSubviews.contains(part) {
                for material in materials(in: part) where material.blendingMode == .behindWindow {
                    material.blendingMode = .withinWindow
                }
            }
        }
        for child in root.subviews { blendWithinWindow(in: child) }
    }

    private static func materials(in view: NSView) -> [NSVisualEffectView] {
        [view as? NSVisualEffectView].compactMap { $0 } + view.subviews.flatMap(materials)
    }
}

/// Applies `SidebarDivider` to the window it is placed in, once the split view next to it is built.
struct SidebarDividerFix: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Anchor() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Applies the fix whenever it lands in a window, on the next turn, so the split view beside it exists by then.
    final class Anchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                if let root = self?.window?.contentView { SidebarDivider.blendWithinWindow(in: root) }
            }
        }
    }
}
