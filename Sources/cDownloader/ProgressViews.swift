import AppKit
import cDownloaderCore
import SwiftUI
import UniformTypeIdentifiers

/// Per-download window: numbers, the piece-by-piece bar, a per-download speed limit and controls.
struct ProgressWindow: View {
    let itemID: UUID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showDetails = true
    @State private var limitOn = false
    @State private var limitKB = 200.0

    var body: some View {
        if let item = model.library.item(itemID) {
            let snapshot = model.library.progress[itemID]
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (item.fileName as NSString).pathExtension) ?? .data))
                        .resizable().frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.fileName.isEmpty ? String(localized: "Connecting…") : item.fileName).font(.headline).lineLimit(1).truncationMode(.middle)
                        Text(item.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow { Text("Status").foregroundStyle(.secondary); Text(statusText(item, snapshot)) }
                    GridRow { Text("File size").foregroundStyle(.secondary); Text(Format.bytes(snapshot?.totalBytes ?? item.totalBytes).isEmpty ? String(localized: "Unknown") : Format.bytes(snapshot?.totalBytes ?? item.totalBytes)) }
                    GridRow { Text("Downloaded").foregroundStyle(.secondary); Text(Format.bytes(snapshot?.downloadedBytes ?? item.downloadedBytes)).monospacedDigit() }
                    GridRow { Text("Transfer rate").foregroundStyle(.secondary); Text(Format.speed(snapshot?.bytesPerSecond)).monospacedDigit() }
                    GridRow { Text("Time left").foregroundStyle(.secondary); Text(Format.duration(snapshot?.secondsLeft)).monospacedDigit() }
                    GridRow { Text("Resume capability").foregroundStyle(.secondary); Text(item.resumable ? String(localized: "Yes") : String(localized: "No")) }
                }
                ProgressView(value: fraction(item, snapshot))
                DisclosureGroup("Connections and pieces", isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 6) {
                        SegmentBar(progress: snapshot?.segments, complete: item.status == .completed)
                            .frame(height: 22)
                            .help("Pink marks are where each connection started, blue is downloaded, white is still to do.")
                        if let bars = snapshot?.segments.bars, !bars.isEmpty, item.kind == .file {
                            Table(Array(bars.enumerated()).map { SegmentRowData(index: $0.offset, bar: $0.element) }) {
                                TableColumn("N.") { Text("\($0.index + 1)").monospacedDigit() }.width(30)
                                TableColumn("Downloaded") { Text(Format.bytes($0.bar.downloadedBytes)).monospacedDigit() }
                                TableColumn("Left") { Text(Format.bytes($0.bar.remainingBytes)).monospacedDigit() }
                                TableColumn("Info") { Text($0.bar.isActive ? String(localized: "Receiving data…") : ($0.bar.remainingBytes == 0 ? String(localized: "Done") : String(localized: "Waiting"))) }
                            }
                            .frame(height: 120)
                        }
                        Text("\(snapshot?.activeConnections ?? 0) active connections").font(.caption).foregroundStyle(.secondary)
                    }
                }
                GroupBox("Speed Limiter") {
                    HStack {
                        Toggle("Limit this download to", isOn: $limitOn)
                        TextField("", value: $limitKB, format: .number).frame(width: 70)
                        Text("KB/s")
                        Spacer()
                    }
                    .onChange(of: limitOn) { _, _ in applyLimit() }
                    .onChange(of: limitKB) { _, _ in if limitOn { applyLimit() } }
                }
                HStack {
                    Spacer()
                    if item.status == .downloading {
                        Button("Pause") { model.library.pause(itemID) }
                    } else if item.status == .completed {
                        Button("Open") { NSWorkspace.shared.open(item.destinationURL) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.destinationURL]) }
                    } else {
                        Button("Resume") { model.library.start(itemID) }
                    }
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            .padding(16)
            .frame(width: 520)
            .onAppear {
                if let limit = item.speedLimit {
                    limitOn = true
                    limitKB = Double(limit) / 1024
                }
            }
        } else {
            Text("This download was removed.").padding(40)
        }
    }

    private func applyLimit() {
        model.library.setSpeedLimit(itemID, bytesPerSecond: limitOn ? Int64(limitKB * 1024) : nil)
    }

    private func fraction(_ item: DownloadItem, _ snapshot: DownloadProgressSnapshot?) -> Double {
        guard let total = snapshot?.totalBytes ?? item.totalBytes, total > 0 else { return item.status == .completed ? 1 : 0 }
        return min(1, Double(snapshot?.downloadedBytes ?? item.downloadedBytes) / Double(total))
    }

    private func statusText(_ item: DownloadItem, _ snapshot: DownloadProgressSnapshot?) -> String {
        switch item.status {
        case .downloading: snapshot == nil ? String(localized: "Connecting…") : String(localized: "Receiving data…")
        case .completed: String(localized: "Complete")
        case .failed: item.errorMessage ?? String(localized: "Error")
        case .waiting: String(localized: "Waiting in queue")
        case .stopped: String(localized: "Paused")
        }
    }
}

struct SegmentRowData: Identifiable {
    let index: Int
    let bar: SegmentProgress.Bar
    var id: Int { index }
}

/// IDM's progress bar: one band for the file, blue for downloaded parts and pink marks at segment starts.
struct SegmentBar: View {
    let progress: SegmentProgress?
    var complete = false

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(Color(nsColor: .textBackgroundColor)))
            context.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(.secondary.opacity(0.4)))
            if complete && (progress?.bars.isEmpty ?? true) {
                context.fill(Path(roundedRect: rect.insetBy(dx: 0, dy: 2), cornerRadius: 3), with: .color(.blue.opacity(0.75)))
                return
            }
            guard let bars = progress?.bars else { return }
            for bar in bars {
                let start = size.width * bar.startFraction
                let done = size.width * bar.downloadedEndFraction
                if done > start {
                    context.fill(Path(CGRect(x: start, y: 2, width: done - start, height: size.height - 4)), with: .color(.blue.opacity(0.75)))
                }
                context.fill(Path(CGRect(x: start, y: 0, width: 2, height: size.height)), with: .color(.pink))
            }
        }
    }
}

/// Shown when a download finishes: open it, show it, or drag the file somewhere.
struct CompleteWindow: View {
    let itemID: UUID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let item = model.library.item(itemID) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.destinationURL.path))
                        .resizable().frame(width: 56, height: 56)
                        .onDrag { NSItemProvider(contentsOf: item.destinationURL) ?? NSItemProvider() }
                        .help("Drag the file to Finder or another app")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Download complete").font(.headline)
                        Text(item.fileName).lineLimit(1).truncationMode(.middle)
                        Text("\(Format.bytes(item.totalBytes)) · \(item.directory)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Toggle("Don't show this window again", isOn: Binding(
                    get: { !model.library.settings.showCompleteDialog },
                    set: { model.library.settings.showCompleteDialog = !$0 }
                ))
                .font(.caption)
                HStack {
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.destinationURL]); dismiss() }
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Open") { NSWorkspace.shared.open(item.destinationURL); dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
            .frame(width: 460)
        } else {
            Text("This download was removed.").padding(40)
        }
    }
}

/// Lists a remote zip's files and extracts chosen ones without downloading the whole archive.
struct ZipPreviewSheet: View {
    let item: DownloadItem
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [ZipEntry] = []
    @State private var selection: Set<String> = []
    @State private var error: String?
    @State private var loading = true
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Zip preview: \(item.url.lastPathComponent)").font(.headline)
            if loading {
                ProgressView("Reading the archive's table of contents…")
            } else if let error {
                Text(error).foregroundStyle(.red)
            } else {
                Table(entries, selection: $selection) {
                    TableColumn("Name", value: \.name)
                    TableColumn("Size") { Text(Format.bytes(Int64(clamping: $0.uncompressedSize))).monospacedDigit() }.width(90)
                    TableColumn("Packed") { Text(Format.bytes(Int64(clamping: $0.compressedSize))).monospacedDigit() }.width(90)
                }
            }
        }
        .padding()
        .frame(width: 620, height: 440)
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(working ? "Extracting…" : "Extract Selected…") { Task { await extract() } }
                    .disabled(selection.isEmpty || working)
            }
        }
    }

    private var fetcher: HTTPRangeFetcher {
        var headers: [String: String] = ["User-Agent": item.userAgent ?? EngineConfiguration.defaultUserAgent]
        if let referer = item.referer { headers["Referer"] = referer }
        if let cookies = item.cookies { headers["Cookie"] = cookies }
        return HTTPRangeFetcher(headers: headers)
    }

    private func load() async {
        do {
            entries = try await RemoteZipPreview(url: item.finalURL ?? item.url, fetcher: fetcher).listEntries()
        } catch {
            self.error = (error as? ZipPreviewError)?.message ?? error.localizedDescription
        }
        loading = false
    }

    private func extract() async {
        guard let folder = FolderPicker.choose(start: item.directory) else { return }
        working = true
        defer { working = false }
        let preview = RemoteZipPreview(url: item.finalURL ?? item.url, fetcher: fetcher)
        for entry in entries where selection.contains(entry.name) && !entry.isDirectory {
            do {
                let data = try await preview.extract(entry)
                let target = FileNameResolver.uniqueURL(for: URL(fileURLWithPath: folder).appendingPathComponent(FileNameResolver.sanitize(entry.name)))
                try data.write(to: target)
            } catch {
                self.error = (error as? ZipPreviewError)?.message ?? error.localizedDescription
            }
        }
        if error == nil { NSWorkspace.shared.open(URL(fileURLWithPath: folder)) }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let speed = Format.speed(model.totalSpeed)
        Text(model.activeCount == 0 ? String(localized: "No active downloads") : String(localized: "\(model.activeCount) downloading \(speed)"))
        Divider()
        Button("Show cDownloader") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("Add URL…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            model.showAddURL = true
        }
        Toggle("Speed Limiter", isOn: Binding(get: { model.speedLimiterOn }, set: { model.speedLimiterOn = $0 }))
        Toggle("Watch Clipboard", isOn: Binding(
            get: { model.library.settings.clipboardMonitoring },
            set: { model.library.settings.clipboardMonitoring = $0 }
        ))
        Divider()
        Button("Start Main Queue") { model.library.startQueue(DownloadQueue.mainDownloadID) }
        Button("Stop All") { model.library.stopAll() }
        Button("Show Drop Target") { openWindow(id: "dropTarget") }
        Divider()
        Button("Quit cDownloader") { NSApp.terminate(nil) }
    }
}

/// A small always-on-top window that accepts links dragged from a browser.
struct DropTargetView: View {
    @Environment(AppModel.self) private var model
    @State private var targeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(targeted ? Color.accentColor.opacity(0.35) : Color.accentColor.opacity(0.15))
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.down.to.line.circle.fill").font(.system(size: 30))
                    Text("Drop links here").font(.caption)
                }
                .foregroundStyle(Color.accentColor)
            }
            .frame(width: 120, height: 100)
            .padding(6)
            .dropDestination(for: URL.self) { urls, _ in
                model.handleDroppedURLs(urls)
                return true
            } isTargeted: { targeted = $0 }
            .background(WindowLevelSetter(level: .floating))
    }
}

/// Puts the hosting window above others.
struct WindowLevelSetter: NSViewRepresentable {
    let level: NSWindow.Level

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.level = level }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { nsView.window?.level = level }
    }
}
