import AppKit
import cDownloaderCore
import SwiftUI
import UniformTypeIdentifiers

/// Under the list in the main window: the selected download's progress, its piece-by-piece bar, a speed limit
/// for it, and its controls.
struct DownloadDetailsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = model.selectedItems
        Group {
            if items.count == 1, let item = items.first {
                DownloadDetails(item: item).id(item.id)
            } else {
                Text(items.isEmpty ? String(localized: "Select a download to see its progress here.") : String(localized: "\(items.count) downloads selected"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 118)
        .background(.bar)
    }
}

/// One download's numbers, bar, speed limit and buttons.
struct DownloadDetails: View {
    let item: DownloadItem
    @Environment(AppModel.self) private var model
    @State private var limitOn = false
    @State private var limitKB = 200.0

    var body: some View {
        let snapshot = model.library.progress[item.id]
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (item.fileName as NSString).pathExtension) ?? .data))
                    .resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.fileName.isEmpty ? String(localized: "Connecting…") : item.fileName).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(item.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 12)
                Text(summary(snapshot)).monospacedDigit().foregroundStyle(item.status == .failed ? .red : .primary).lineLimit(1)
            }
            if item.status == .completed || !(snapshot?.segments.bars.isEmpty ?? true) {
                SegmentBar(progress: snapshot?.segments, complete: item.status == .completed)
                    .frame(height: 14)
                    .help("Pink marks are where each connection started, blue is downloaded, white is still to do.")
            } else {
                ProgressView(value: fraction(snapshot))
            }
            HStack(spacing: 10) {
                Text(amounts(snapshot)).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                Spacer(minLength: 12)
                Toggle("Limit to", isOn: $limitOn).toggleStyle(.checkbox)
                TextField("", value: $limitKB, format: .number).frame(width: 60)
                Text("KB/s").foregroundStyle(.secondary)
                Divider().frame(height: 16)
                actions
            }
            .controlSize(.small)
            .onChange(of: limitOn) { _, _ in applyLimit() }
            .onChange(of: limitKB) { _, _ in if limitOn { applyLimit() } }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onAppear {
            if let limit = item.speedLimit {
                limitOn = true
                limitKB = Double(limit) / 1024
            }
        }
    }

    @ViewBuilder private var actions: some View {
        switch item.status {
        case .downloading, .waiting:
            Button("Pause") { model.library.pause(item.id) }
        case .completed:
            Button("Open") { NSWorkspace.shared.open(item.destinationURL) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.destinationURL]) }
        case .stopped, .failed:
            Button("Resume") { model.library.start(item.id) }
        }
    }

    private func applyLimit() {
        model.library.setSpeedLimit(item.id, bytesPerSecond: limitOn ? Int64(limitKB * 1024) : nil)
    }

    private func fraction(_ snapshot: DownloadProgressSnapshot?) -> Double {
        guard let total = snapshot?.totalBytes ?? item.totalBytes, total > 0 else { return item.status == .completed ? 1 : 0 }
        return min(1, Double(snapshot?.downloadedBytes ?? item.downloadedBytes) / Double(total))
    }

    /// "45% · 8 MB/s · 2 min left" while downloading; otherwise the status in words.
    private func summary(_ snapshot: DownloadProgressSnapshot?) -> String {
        switch item.status {
        case .downloading:
            guard let snapshot else { return String(localized: "Connecting…") }
            let known = snapshot.totalBytes.map { $0 > 0 } ?? false
            let parts = [known ? String(format: "%.1f%%", fraction(snapshot) * 100) : "", Format.speed(snapshot.bytesPerSecond), Format.duration(snapshot.secondsLeft)]
            return parts.filter { !$0.isEmpty }.joined(separator: " · ")
        case .completed: return String(localized: "Complete")
        case .failed: return item.errorMessage ?? String(localized: "Error")
        case .waiting: return withPercent(String(localized: "Waiting in queue"), snapshot)
        case .stopped: return withPercent(String(localized: "Paused"), snapshot)
        }
    }

    /// "Paused · 45.0%" when the size is known, in the list's format.
    private func withPercent(_ status: String, _ snapshot: DownloadProgressSnapshot?) -> String {
        guard let total = snapshot?.totalBytes ?? item.totalBytes, total > 0 else { return status }
        return "\(status) · " + String(format: "%.1f%%", fraction(snapshot) * 100)
    }

    /// "450 MB of 1 GB · 8 connections · Can resume"
    private func amounts(_ snapshot: DownloadProgressSnapshot?) -> String {
        let done = Format.bytes(snapshot?.downloadedBytes ?? item.downloadedBytes)
        let total = Format.bytes(snapshot?.totalBytes ?? item.totalBytes)
        var parts = [total.isEmpty ? done : String(localized: "\(done) of \(total)")]
        if item.status == .downloading { parts.append(String(localized: "\(snapshot?.activeConnections ?? 0) connections")) }
        parts.append(item.resumable ? String(localized: "Can resume") : String(localized: "Cannot resume"))
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
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

/// The note at the top of the main window when a download finishes: open it, show it, or drag the file somewhere.
/// It fades away by itself.
struct CompletionBanner: View {
    let item: DownloadItem
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.destinationURL.path))
                .resizable().frame(width: 28, height: 28)
                .onDrag { NSItemProvider(contentsOf: item.destinationURL) ?? NSItemProvider() }
                .help("Drag the file to Finder or another app")
            VStack(alignment: .leading, spacing: 1) {
                Text("Download complete").font(.caption).foregroundStyle(.secondary)
                Text(item.fileName).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.destinationURL]); model.completionBanner = nil }
            Button("Open") { NSWorkspace.shared.open(item.destinationURL); model.completionBanner = nil }
                .buttonStyle(.borderedProminent)
            Button { model.completionBanner = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Close")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
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
