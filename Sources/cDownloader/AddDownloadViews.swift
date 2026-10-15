import AppKit
import cDownloaderCore
import SwiftUI

/// "Add URL": type or paste an address, optionally with a login.
struct AddURLSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let prefill: String
    @State private var address = ""
    @State private var useLogin = false
    @State private var user = ""
    @State private var password = ""

    var body: some View {
        Form {
            Section {
                TextField("Address", text: $address, prompt: Text("https://example.com/file.zip"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
            } header: {
                Text("Download address")
            }
            Section {
                Toggle("The server needs a login", isOn: $useLogin)
                if useLogin {
                    TextField("User name", text: $user)
                    SecureField("Password", text: $password)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear {
            address = prefill
            if address.isEmpty, let text = NSPasteboard.general.string(forType: .string), validURL(text) != nil {
                address = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("OK", action: add).disabled(validURL(address) == nil) }
        }
    }

    private func validURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ["http", "https", "ftp"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    private func add() {
        guard let url = validURL(address) else { return }
        dismiss()
        let credentials = useLogin && !user.isEmpty ? Credentials(user: user, password: password) : nil
        DispatchQueue.main.async { model.offer(url, credentials: credentials) }
    }
}

/// IDM's "Download File Info": category, folder, name and description before starting.
struct DownloadInfoSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var item: DownloadItem
    @State private var queueID = DownloadQueue.mainDownloadID
    @State private var size: Int64?
    @State private var probing = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Address") {
                    Text(item.url.absoluteString).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                LabeledContent("Size") {
                    if case .webVideo = item.kind, WebVideoLinks.site(of: item.url) == .facebook {
                        Text("Facebook video (size known once downloaded)")
                    } else if case .webVideo = item.kind {
                        Text("YouTube video (size known once downloaded)")
                    } else if item.kind != .file {
                        Text("Video stream (size known once downloaded)")
                    } else if probing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(Format.bytes(size).isEmpty ? String(localized: "Unknown") : Format.bytes(size))
                    }
                }
                if case .webVideo(let quality) = item.kind {
                    Picker("Quality", selection: Binding(get: { quality }, set: { item.kind = .webVideo(quality: $0) })) {
                        ForEach(VideoQuality.allCases, id: \.self) { choice in Text(choice.label).tag(choice) }
                    }
                }
            }
            Section {
                Picker("Category", selection: Binding(
                    get: { item.categoryID ?? DownloadCategory.generalID },
                    set: { id in
                        item.categoryID = id
                        if let folder = model.library.categories.first(where: { $0.id == id })?.folder { item.directory = folder }
                    }
                )) {
                    ForEach(model.library.categories) { category in Text(category.name).tag(category.id) }
                }
                HStack {
                    TextField("Save to", text: $item.directory)
                    Button("Choose…") {
                        if let folder = FolderPicker.choose(start: item.directory) { item.directory = folder }
                    }
                }
                TextField("File name", text: $item.fileName, prompt: Text(fileNamePrompt))
                TextField("Description", text: $item.descriptionText)
            }
            if item.url.pathExtension.lowercased() == "zip" {
                Section {
                    Button("Preview Zip Contents…") { model.zipPreviewItem = item; dismiss() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .task { await probe() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .secondaryAction) {
                Menu("Download Later") {
                    ForEach(model.library.queues.filter { $0.kind == .download }) { queue in
                        Button(queue.name) { finish(startNow: false, queue: queue.id) }
                    }
                } primaryAction: {
                    finish(startNow: false, queue: DownloadQueue.mainDownloadID)
                }
            }
            ToolbarItem(placement: .confirmationAction) { Button("Start Download") { finish(startNow: true, queue: nil) } }
        }
    }

    private var fileNamePrompt: String {
        switch item.kind {
        case .file: String(localized: "Decided by the server")
        case .hls: String(localized: "Taken from the stream")
        case .webVideo: String(localized: "Taken from the video title")
        }
    }

    private func finish(startNow: Bool, queue: UUID?) {
        model.confirm(item, startNow: startNow, queueID: queue)
        dismiss()
    }

    /// Asks the server for the size and the real file name while the dialog is open.
    private func probe() async {
        // A stream's address is a playlist; its size and name say nothing about the video.
        guard item.kind == .file, ["http", "https"].contains(item.url.scheme?.lowercased() ?? "") else { return }
        probing = true
        defer { probing = false }
        var request = URLRequest(url: item.url)
        request.httpMethod = "HEAD"
        request.setValue(item.userAgent ?? EngineConfiguration.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        if let referer = item.referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        if let cookies = item.cookies { request.setValue(cookies, forHTTPHeaderField: "Cookie") }
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return }
        size = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
        if item.fileName.isEmpty {
            let disposition = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
            item.fileName = FileNameResolver.fileName(contentDisposition: disposition, url: response.url ?? item.url, mimeType: response.mimeType)
            if let category = CategoryCatalog.suggest(fileName: item.fileName, in: model.library.categories), category.id != item.categoryID {
                item.categoryID = category.id
                item.directory = category.folder
            }
        }
    }
}

/// Pick which of many links to download ("download all links", imports, drops).
struct SelectLinksSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let items: [DownloadItem]
    @State private var checked: Set<UUID> = []
    @State private var hidePages = true
    @State private var filter = ""
    @State private var folder = ""
    @State private var queueID = DownloadQueue.mainDownloadID

    private static let pageExtensions: Set<String> = ["", "html", "htm", "php", "asp", "aspx", "jsp", "shtml"]

    private var shown: [DownloadItem] {
        items.filter { item in
            let ext = item.url.pathExtension.lowercased()
            if hidePages && Self.pageExtensions.contains(ext) { return false }
            return filter.isEmpty || item.url.absoluteString.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose the files to download").font(.headline)
            HStack {
                TextField("Filter", text: $filter, prompt: Text("Show only addresses containing…"))
                Toggle("Hide web pages", isOn: $hidePages)
            }
            List(shown) { item in
                Toggle(isOn: Binding(
                    get: { checked.contains(item.id) },
                    set: { if $0 { checked.insert(item.id) } else { checked.remove(item.id) } }
                )) {
                    VStack(alignment: .leading) {
                        Text(item.fileName.isEmpty ? item.url.lastPathComponent : item.fileName)
                        Text(item.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .frame(minHeight: 260)
            HStack {
                Button("Check All") { checked.formUnion(shown.map(\.id)) }
                Button("Uncheck All") { checked.subtract(shown.map(\.id)) }
                Spacer()
                Text("\(checked.intersection(Set(shown.map(\.id))).count) of \(shown.count) selected").foregroundStyle(.secondary)
            }
            HStack {
                TextField("Save to (empty uses each file's category folder)", text: $folder)
                Button("Choose…") { if let picked = FolderPicker.choose(start: folder.isEmpty ? nil : folder) { folder = picked } }
            }
            Picker("Add to queue", selection: $queueID) {
                ForEach(model.library.queues.filter { $0.kind == .download }) { queue in Text(queue.name).tag(queue.id) }
            }
        }
        .padding()
        .frame(width: 680, height: 520)
        .onAppear { checked = Set(shown.map(\.id)) }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .secondaryAction) { Button("Add to Queue") { finish(start: false) } }
            ToolbarItem(placement: .confirmationAction) { Button("Download Now") { finish(start: true) } }
        }
    }

    private func finish(start: Bool) {
        let chosen = items.filter { checked.contains($0.id) && shown.contains($0) }.map { item -> DownloadItem in
            var item = item
            if !folder.isEmpty { item.directory = folder }
            return item
        }
        model.addMany(chosen, startNow: start, queueID: queueID)
        dismiss()
    }
}

/// Batch download: one address with `*` replaced by a number or letter range.
struct BatchDownloadSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var template = "https://example.com/images/photo*.jpg"
    @State private var useLetters = false
    @State private var from = 1
    @State private var to = 10
    @State private var width = 0
    @State private var fromLetter = "a"
    @State private var toLetter = "z"
    @State private var queueID = DownloadQueue.mainDownloadID

    private var result: Result<[URL], Error> {
        let range: BatchPattern.Range = useLetters
            ? .letters(from: fromLetter.first ?? "a", to: toLetter.first ?? "z")
            : .numbers(from: from, to: to, width: width)
        return Result { try BatchPattern.expand(template, range: range) }
    }

    var body: some View {
        Form {
            Section {
                TextField("Address with *", text: $template)
                Text("Put a * where the number or letter goes, for example …/photo*.jpg").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Replace * with", selection: $useLetters) {
                    Text("Numbers").tag(false)
                    Text("Letters").tag(true)
                }
                .pickerStyle(.segmented)
                if useLetters {
                    HStack {
                        TextField("From", text: $fromLetter)
                        TextField("To", text: $toLetter)
                    }
                } else {
                    HStack {
                        TextField("From", value: $from, format: .number)
                        TextField("To", value: $to, format: .number)
                        Stepper("Digits: \(width == 0 ? String(localized: "any") : String(width))", value: $width, in: 0...8)
                    }
                }
            }
            Section("Preview") {
                switch result {
                case .success(let urls):
                    Text("\(urls.count) files").bold()
                    if let first = urls.first { Text(first.absoluteString).font(.caption) }
                    if urls.count > 1, let last = urls.last { Text("…").font(.caption); Text(last.absoluteString).font(.caption) }
                case .failure(let error):
                    Text(message(for: error)).foregroundStyle(.red)
                }
            }
            Picker("Add to queue", selection: $queueID) {
                ForEach(model.library.queues.filter { $0.kind == .download }) { queue in Text(queue.name).tag(queue.id) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    if case .success(let urls) = result {
                        let items = urls.map { model.library.makeItem(from: IncomingDownload(url: $0), folder: nil) }
                        model.addMany(items, startNow: false, queueID: queueID)
                    }
                    dismiss()
                }
                .disabled((try? result.get()) == nil)
            }
        }
    }

    private func message(for error: Error) -> String {
        switch error as? BatchPattern.BatchError {
        case .noWildcard: String(localized: "Add one * to the address.")
        case .multipleWildcards: String(localized: "Use only one * in the address.")
        case .reversedRange: String(localized: "The start must come before the end.")
        case .invalidAddress(let text): String(localized: "Not a valid address: \(text)")
        case nil: error.localizedDescription
        }
    }
}

/// Download properties: address, name, folder, description and login.
struct PropertiesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var item: DownloadItem
    @State private var address = ""
    @State private var password = ""

    var body: some View {
        Form {
            Section {
                TextField("Address", text: $address)
                LabeledContent("Final address", value: item.finalURL?.absoluteString ?? String(localized: "Not known yet"))
                TextField("Referer", text: Binding(get: { item.referer ?? "" }, set: { item.referer = $0.isEmpty ? nil : $0 }))
            }
            Section {
                TextField("File name", text: $item.fileName)
                HStack {
                    TextField("Folder", text: $item.directory)
                    Button("Choose…") { if let folder = FolderPicker.choose(start: item.directory) { item.directory = folder } }
                }
                Picker("Category", selection: Binding(get: { item.categoryID ?? DownloadCategory.generalID }, set: { item.categoryID = $0 })) {
                    ForEach(model.library.categories) { category in Text(category.name).tag(category.id) }
                }
                TextField("Description", text: $item.descriptionText)
            }
            Section("Login") {
                TextField("User name", text: Binding(get: { item.username ?? "" }, set: { item.username = $0.isEmpty ? nil : $0 }))
                SecureField("Password", text: $password)
            }
            Section("Connections") {
                Stepper("Connections: \(item.maxConnections.map(String.init) ?? String(localized: "default"))", value: Binding(
                    get: { item.maxConnections ?? 0 },
                    set: { item.maxConnections = $0 == 0 ? nil : $0 }
                ), in: 0...32)
                LabeledContent("Size", value: Format.bytes(item.totalBytes))
                LabeledContent("Resumable", value: item.resumable ? String(localized: "Yes") : String(localized: "No"))
                if let error = item.errorMessage { LabeledContent("Last error", value: error) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .onAppear {
            address = item.url.absoluteString
            password = model.library.secrets.password(for: item.credentialKey) ?? ""
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if let url = URL(string: address.trimmingCharacters(in: .whitespaces)), url.scheme != nil, url != item.url {
                        item.url = url
                        item.finalURL = nil
                    }
                    model.library.secrets.setPassword(item.username == nil ? nil : password, for: item.credentialKey)
                    model.library.update(item)
                    dismiss()
                }
            }
        }
    }
}
