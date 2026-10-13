import AppKit
import cDownloaderCore
import SwiftUI

/// The main list of downloads with IDM's columns; columns can be hidden and reordered.
struct DownloadTable: View {
    @Environment(AppModel.self) private var model
    @AppStorage("showDetailsPanel") private var showDetailsPanel = true
    @State private var sortOrder = [KeyPathComparator(\DownloadRow.dateAdded, order: .reverse)]
    @AppStorage("tableColumns") private var columnStorage = TableColumnCustomization<DownloadRow>()

    var body: some View {
        @Bindable var model = model
        let rows = model.visibleItems.map { DownloadRow(item: $0, progress: model.library.progress[$0.id], queues: model.library.queues) }
            .sorted(using: sortOrder)
        Table(of: DownloadRow.self, selection: $model.selection, sortOrder: $sortOrder, columnCustomization: $columnStorage) {
            TableColumn("File Name", value: \.fileName) { row in
                HStack(spacing: 6) {
                    Image(nsImage: row.icon).resizable().frame(width: 16, height: 16)
                    Text(row.fileName).lineLimit(1).truncationMode(.middle)
                }
                .help(row.item.url.absoluteString)
            }
            .width(min: 160, ideal: 300)
            .customizationID("name")

            TableColumn("Q", value: \.queueMark) { row in
                Image(systemName: row.queueSymbol).foregroundStyle(row.queueColor).help(row.queueName)
            }
            .width(24)
            .customizationID("queue")

            TableColumn("Size", value: \.sizeSort) { row in
                Text(row.sizeText).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            .customizationID("size")

            TableColumn("Status", value: \.statusSort) { row in
                StatusCell(row: row)
            }
            .width(min: 90, ideal: 130)
            .customizationID("status")

            TableColumn("Time Left", value: \.secondsLeftSort) { row in
                Text(row.timeLeftText).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
            .customizationID("timeLeft")

            TableColumn("Transfer Rate", value: \.speedSort) { row in
                Text(row.speedText).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
            .customizationID("speed")

            TableColumn("Last Try", value: \.lastTrySort) { row in
                Text(Format.date(row.item.lastTry)).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 130)
            .customizationID("lastTry")

            TableColumn("Description", value: \.descriptionText) { row in
                Text(row.descriptionText).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 160)
            .customizationID("description")

            TableColumn("Added", value: \.dateAdded) { row in
                Text(Format.date(row.dateAdded)).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 130)
            .customizationID("added")
            .defaultVisibility(.hidden)
        } rows: {
            ForEach(rows) { row in
                TableRow(row)
                    .itemProvider { provider(for: row.item) }
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            RowMenu(ids: ids)
        } primaryAction: { ids in
            for id in ids { primaryAction(id) }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView {
                    Label("No downloads here", systemImage: "arrow.down.circle")
                } description: {
                    Text("Add an address with ⌘N, drop a link here, or copy a download link.")
                }
            }
        }
    }

    /// Drag a finished file out to Finder or another app; otherwise drag the item to a queue.
    private func provider(for item: DownloadItem) -> NSItemProvider? {
        if item.status == .completed, FileManager.default.fileExists(atPath: item.destinationURL.path) {
            return NSItemProvider(contentsOf: item.destinationURL)
        }
        return NSItemProvider(object: item.id.uuidString as NSString)
    }

    private func primaryAction(_ id: UUID) {
        guard let item = model.library.item(id) else { return }
        if item.status == .completed {
            NSWorkspace.shared.open(item.destinationURL)
        } else {
            model.selection = [id]
            showDetailsPanel = true
        }
    }
}

struct StatusCell: View {
    let row: DownloadRow

    private var showsBar: Bool {
        row.item.status == .downloading || (row.item.status == .stopped && row.item.downloadedBytes > 0)
    }

    var body: some View {
        if showsBar {
            HStack(spacing: 6) {
                ProgressView(value: row.fraction).progressViewStyle(.linear).frame(minWidth: 40)
                Text(row.statusText).monospacedDigit().font(.caption).foregroundStyle(.secondary)
            }
        } else {
            label
        }
    }

    @ViewBuilder private var label: some View {
        switch row.item.status {
        case .failed:
            Text(row.statusText).foregroundStyle(.red).help(row.item.errorMessage ?? "")
        case .completed:
            Text(row.statusText).foregroundStyle(.green)
        default:
            Text(row.statusText).foregroundStyle(.secondary)
        }
    }
}

struct RowMenu: View {
    let ids: Set<UUID>
    @Environment(AppModel.self) private var model
    @AppStorage("showDetailsPanel") private var showDetailsPanel = true

    var body: some View {
        let items = ids.compactMap { model.library.item($0) }
        if let first = items.first {
            if first.status == .completed {
                Button("Open") { items.forEach { NSWorkspace.shared.open($0.destinationURL) } }
                Menu("Open With") {
                    ForEach(NSWorkspace.shared.urlsForApplications(toOpen: first.destinationURL), id: \.self) { app in
                        Button(app.deletingPathExtension().lastPathComponent) {
                            NSWorkspace.shared.open([first.destinationURL], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                        }
                    }
                }
            }
            Button("Show in Finder") { reveal(items) }
            Divider()
            Button("Resume Download") { ids.forEach { model.library.start($0) } }
                .disabled(!items.contains { $0.status != .completed && $0.status != .downloading })
            Button("Stop Download") { ids.forEach { model.library.pause($0) } }
                .disabled(!items.contains { $0.status == .downloading })
            Button("Redownload") { ids.forEach { model.library.redownload($0) } }
            Button("Refresh Download Address") { ids.forEach { model.library.requestAddressRefresh($0) } }
                .help("Open the download page again in your browser; cDownloader takes the new link for this file")
            Button("Show Progress") { model.selection = ids; showDetailsPanel = true }
            Divider()
            Menu("Move to Queue") {
                ForEach(model.library.queues) { queue in
                    Button(queue.name) { model.library.moveItems(Array(ids), toQueue: queue.id) }
                }
                Divider()
                Button("Remove from Queues") { model.library.moveItems(Array(ids), toQueue: nil) }
            }
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(items.map(\.url.absoluteString).joined(separator: "\n"), forType: .string)
            }
            if first.url.pathExtension.lowercased() == "zip" {
                Button("Preview Zip Contents…") { model.zipPreviewItem = first }
            }
            Divider()
            Button("Properties…") { model.propertiesItem = first }
            Button("Remove from List") {
                model.library.remove(ids, deleteFiles: false)
                model.selection.subtract(ids)
            }
            Button("Remove and Move File to Trash", role: .destructive) {
                model.library.remove(ids, deleteFiles: true)
                model.selection.subtract(ids)
            }
            .help("Removes the download and moves its file to the Trash; unfinished downloads lose their partial data")
        }
    }

    private func reveal(_ items: [DownloadItem]) {
        let urls = items.map { item -> URL in
            FileManager.default.fileExists(atPath: item.destinationURL.path) ? item.destinationURL : URL(fileURLWithPath: item.directory, isDirectory: true)
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

/// One table row: the item plus everything the columns sort on.
struct DownloadRow: Identifiable {
    let item: DownloadItem
    let progress: DownloadProgressSnapshot?
    let queueName: String
    let isSyncQueue: Bool

    init(item: DownloadItem, progress: DownloadProgressSnapshot?, queues: [DownloadQueue]) {
        self.item = item
        self.progress = progress
        let queue = item.queueID.flatMap { id in queues.first { $0.id == id } }
        queueName = queue?.name ?? ""
        isSyncQueue = queue?.kind == .synchronization
    }

    var id: UUID { item.id }
    var fileName: String { item.fileName.isEmpty ? item.url.lastPathComponent : item.fileName }
    var descriptionText: String { item.descriptionText }
    var dateAdded: Date { item.dateAdded }
    var lastTrySort: Date { item.lastTry ?? .distantPast }
    var total: Int64? { progress?.totalBytes ?? item.totalBytes }
    var sizeSort: Int64 { total ?? -1 }
    var sizeText: String { Format.bytes(total) }
    var statusText: String { Format.status(item, progress: progress) }
    var statusSort: String { "\(item.status.rawValue)\(String(format: "%08.3f", fraction * 1000))" }
    var fraction: Double {
        guard let total, total > 0 else { return item.status == .completed ? 1 : 0 }
        return min(1, Double(progress?.downloadedBytes ?? item.downloadedBytes) / Double(total))
    }
    var secondsLeftSort: Double { progress?.secondsLeft ?? .infinity }
    var timeLeftText: String { item.status == .downloading ? Format.duration(progress?.secondsLeft) : "" }
    var speedSort: Double { progress?.bytesPerSecond ?? 0 }
    var speedText: String { item.status == .downloading ? Format.speed(progress?.bytesPerSecond) : "" }
    var queueMark: String { queueName }
    var queueSymbol: String { queueName.isEmpty ? "" : (isSyncQueue ? "arrow.triangle.2.circlepath" : "square.stack.3d.down.forward") }
    var queueColor: Color { isSyncQueue ? .green : .orange }

    var icon: NSImage {
        let ext = (fileName as NSString).pathExtension
        return NSWorkspace.shared.icon(for: .init(filenameExtension: ext.isEmpty ? "data" : ext) ?? .data)
    }
}
