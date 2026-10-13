import AppKit
import cDownloaderCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            FileTypeSettings().tabItem { Label("File Types", systemImage: "doc.on.doc") }
            ConnectionSettings().tabItem { Label("Connection", systemImage: "network") }
            SaveToSettings().tabItem { Label("Save To", systemImage: "folder") }
            DownloadSettings().tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            ProxySettingsView().tabItem { Label("Proxy", systemImage: "server.rack") }
            SiteLoginSettings().tabItem { Label("Site Logins", systemImage: "key") }
            SoundSettingsView().tabItem { Label("Sounds", systemImage: "speaker.wave.2") }
            SpeedLimiterSettingsView().tabItem { Label("Speed Limiter", systemImage: "gauge.with.dots.needle.33percent") }
            BrowserSettingsView().tabItem { Label("Browser", systemImage: "safari") }
            VideoSiteSettings().tabItem { Label("Video Sites", systemImage: "play.rectangle") }
        }
        .frame(width: 780, height: 520)
    }
}

/// Binding helpers into `library.settings`.
extension AppModel {
    /// Writes only real changes: SwiftUI may set a binding to the value it already has, and every
    /// write saves the settings and redraws, which would otherwise loop.
    func setting<Value: Equatable>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.library.settings[keyPath: keyPath] },
            set: { if self.library.settings[keyPath: keyPath] != $0 { self.library.settings[keyPath: keyPath] = $0 } }
        )
    }

    func listSetting(_ keyPath: WritableKeyPath<AppSettings, [String]>, separator: String = "\n") -> Binding<String> {
        Binding(
            get: { self.library.settings[keyPath: keyPath].joined(separator: separator) },
            set: { text in
                let values = text
                    .split(whereSeparator: { separator == " " ? ($0 == " " || $0 == "," || $0.isNewline) : $0.isNewline })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if self.library.settings[keyPath: keyPath] != values { self.library.settings[keyPath: keyPath] = values }
            }
        )
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Toggle("Open cDownloader when I log in", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in LaunchAtLogin.set(on) }
            Toggle("Take over downloads from browsers", isOn: model.setting(\.browserIntegration))
            Toggle("Watch the clipboard for download links", isOn: model.setting(\.clipboardMonitoring))
            Toggle("Show the icon in the menu bar", isOn: model.setting(\.showMenuBarIcon))
            Toggle("Keep running in the menu bar when the window is closed", isOn: model.setting(\.hideDockIconWhenClosed))
                .disabled(!model.library.settings.showMenuBarIcon)
            Text("With no window open, cDownloader leaves the Dock and keeps downloading. Its icon in the menu bar opens it again or quits it. This needs the menu bar icon.")
                .font(.caption).foregroundStyle(.secondary)
            Section("Special keys when clicking a link in the browser") {
                Picker("Hold to let the browser download", selection: model.setting(\.browser.skipModifier)) {
                    Text("None").tag(String?.none)
                    Text("Option ⌥").tag(String?.some("alt"))
                    Text("Shift ⇧").tag(String?.some("shift"))
                    Text("Command ⌘").tag(String?.some("meta"))
                }
                Picker("Hold to force cDownloader", selection: model.setting(\.browser.forceModifier)) {
                    Text("None").tag(String?.none)
                    Text("Option ⌥").tag(String?.some("alt"))
                    Text("Shift ⇧").tag(String?.some("shift"))
                    Text("Control ⌃").tag(String?.some("ctrl"))
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct FileTypeSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Take over these file types from browsers") {
                TextEditor(text: model.listSetting(\.capturedExtensions, separator: " "))
                    .font(.body.monospaced()).frame(height: 110)
                Button("Restore Defaults") { model.library.settings.capturedExtensions = AppSettings.defaultCapturedExtensions }
            }
            Section("Never take over downloads from these sites (one per line, * as wildcard)") {
                TextEditor(text: model.listSetting(\.dontCaptureSites)).font(.body.monospaced()).frame(height: 80)
            }
            Section("Never take over these addresses") {
                TextEditor(text: model.listSetting(\.addressExceptions)).font(.body.monospaced()).frame(height: 60)
            }
        }
        .formStyle(.grouped)
    }
}

struct ConnectionSettings: View {
    @Environment(AppModel.self) private var model
    @State private var newPattern = ""
    @State private var newLimit = 1

    var body: some View {
        Form {
            Section("Connections") {
                Stepper("Connections per download: \(model.library.settings.maxConnections)", value: model.setting(\.maxConnections), in: 1...32)
                Text("More connections can be faster, but some servers limit or block many connections from one computer.").font(.caption).foregroundStyle(.secondary)
                Stepper("Timeout: \(model.library.settings.timeoutSeconds) seconds", value: model.setting(\.timeoutSeconds), in: 5...300, step: 5)
                Stepper("Retries per connection: \(model.library.settings.retriesPerConnection)", value: model.setting(\.retriesPerConnection), in: 0...50)
            }
            Section("Servers with their own connection limit") {
                ForEach(model.library.settings.connectionExceptions) { rule in
                    HStack {
                        Text(rule.hostPattern)
                        Spacer()
                        Text("\(rule.maxConnections) connections").foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            model.library.settings.connectionExceptions.removeAll { $0.id == rule.id }
                        } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Server (for example *.example.com)", text: $newPattern)
                    Stepper("\(newLimit)", value: $newLimit, in: 1...32).fixedSize()
                    Button("Add") {
                        model.library.settings.connectionExceptions.append(ConnectionException(hostPattern: newPattern, maxConnections: newLimit))
                        newPattern = ""
                    }
                    .disabled(newPattern.isEmpty)
                }
            }
            Section("Download limits") {
                Toggle("Limit how much I download", isOn: model.setting(\.quota.enabled))
                Stepper("At most \(model.library.settings.quota.megabytes) MB", value: model.setting(\.quota.megabytes), in: 10...100_000, step: 10)
                Stepper("every \(model.library.settings.quota.hours) hours", value: model.setting(\.quota.hours), in: 1...168)
                Text("Useful for connections with a fair-use limit: downloads pause when the limit is reached and continue later.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct SaveToSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Default folder for each category") {
                ForEach(model.library.categories) { category in
                    HStack {
                        Text(category.name).frame(width: 110, alignment: .leading)
                        Text(category.folder).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        Spacer()
                        Button("Change…") {
                            if let folder = FolderPicker.choose(start: category.folder) {
                                var updated = category
                                updated.folder = folder
                                model.library.updateCategory(updated)
                            }
                        }
                    }
                }
            }
            Toggle("Remember the last folder I picked for each category", isOn: model.setting(\.rememberLastSavePath))
            Section("Temporary folder for unfinished downloads") {
                HStack {
                    Text(model.library.settings.temporaryDirectory ?? AppPaths.temporaryDirectory.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button("Change…") {
                        if let folder = FolderPicker.choose(start: model.library.settings.temporaryDirectory) { model.library.settings.temporaryDirectory = folder }
                    }
                    Button("Default") { model.library.settings.temporaryDirectory = nil }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct DownloadSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Windows") {
                Toggle("Ask where to save before starting (Download File Info)", isOn: model.setting(\.showStartDialog))
                Picker("When a download starts", selection: Binding(
                    get: { model.library.settings.progressWindow == .hidden ? ProgressWindowMode.hidden : .show },
                    set: { model.library.settings.progressWindow = $0 }
                )) {
                    Text("Select it, to show its progress under the list").tag(ProgressWindowMode.show)
                    Text("Keep the current selection").tag(ProgressWindowMode.hidden)
                }
                Toggle("Show a banner in the main window when a download completes", isOn: model.setting(\.showCompleteDialog))
            }
            Section("Behavior") {
                Toggle("Ignore file date changes when resuming", isOn: model.setting(\.ignoreModificationTimeChanges))
                Text("Some servers change a file's date on every request; turn this on if such downloads keep starting over.").font(.caption).foregroundStyle(.secondary)
                TextField("User-Agent for addresses I add myself", text: Binding(
                    get: { model.library.settings.customUserAgent ?? "" },
                    set: { model.library.settings.customUserAgent = $0.isEmpty ? nil : $0 }
                ), prompt: Text(EngineConfiguration.defaultUserAgent))
            }
            Section("Virus check after download") {
                Toggle("Scan finished files", isOn: model.setting(\.scan.enabled))
                HStack {
                    TextField("Scanner program", text: model.setting(\.scan.executablePath), prompt: Text("/opt/homebrew/bin/clamscan"))
                    Button("Choose…") { if let file = FolderPicker.chooseFile() { model.library.settings.scan.executablePath = file.path } }
                }
                TextField("Arguments (%f is the file)", text: model.setting(\.scan.arguments))
            }
            Section("Video streams") {
                LabeledContent("Join sound and video into one .mp4") {
                    Text(FFmpeg.locate() == nil ? String(localized: "Off: ffmpeg is missing. Reinstall cDownloader.") : String(localized: "On"))
                        .foregroundStyle(.secondary)
                }
                Text("Without ffmpeg, streams are saved as .ts files, and a separate sound track is saved next to the video.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ProxySettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""

    var body: some View {
        Form {
            Picker("Proxy", selection: model.setting(\.proxy.mode)) {
                Text("Use the Mac's network settings").tag(ProxyMode.system)
                Text("No proxy").tag(ProxyMode.none)
                Text("Manual").tag(ProxyMode.manual)
            }
            .pickerStyle(.radioGroup)
            if model.library.settings.proxy.mode == .manual {
                Section("HTTP") {
                    TextField("Server", text: model.setting(\.proxy.httpHost))
                    TextField("Port", value: model.setting(\.proxy.httpPort), format: .number.grouping(.never))
                    Toggle("Use the same proxy for HTTPS", isOn: model.setting(\.proxy.sameProxyForHTTPS))
                }
                if !model.library.settings.proxy.sameProxyForHTTPS {
                    Section("HTTPS") {
                        TextField("Server", text: model.setting(\.proxy.httpsHost))
                        TextField("Port", value: model.setting(\.proxy.httpsPort), format: .number.grouping(.never))
                    }
                }
                Section("SOCKS") {
                    TextField("Server", text: model.setting(\.proxy.socksHost))
                    TextField("Port", value: model.setting(\.proxy.socksPort), format: .number.grouping(.never))
                }
                Section("Login") {
                    TextField("User name", text: Binding(
                        get: { model.library.settings.proxy.username ?? "" },
                        set: { model.library.settings.proxy.username = $0.isEmpty ? nil : $0 }
                    ))
                    SecureField("Password", text: $password)
                        .onSubmit { model.library.secrets.setPassword(password, for: ProxySettings.credentialKey) }
                        .onChange(of: password) { _, value in model.library.secrets.setPassword(value, for: ProxySettings.credentialKey) }
                }
                Section("Don't use the proxy for (one per line)") {
                    TextEditor(text: model.listSetting(\.proxy.bypass)).font(.body.monospaced()).frame(height: 60)
                }
            }
            Toggle("Use passive mode for FTP", isOn: model.setting(\.proxy.ftpPassiveMode)).disabled(true)
                .help("cDownloader always uses passive FTP, which works behind routers and firewalls.")
        }
        .formStyle(.grouped)
        .onAppear { password = model.library.secrets.password(for: ProxySettings.credentialKey) ?? "" }
    }
}

struct SiteLoginSettings: View {
    @Environment(AppModel.self) private var model
    @State private var prefix = ""
    @State private var user = ""
    @State private var password = ""

    var body: some View {
        Form {
            Section("Saved logins (the longest matching address wins)") {
                ForEach(model.library.settings.siteLogins) { login in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(login.urlPrefix)
                            Text(login.username).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            model.library.secrets.setPassword(nil, for: login.credentialKey)
                            model.library.settings.siteLogins.removeAll { $0.id == login.id }
                        } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
            }
            Section("Add a login") {
                TextField("Address starts with", text: $prefix, prompt: Text("https://example.com/members/"))
                TextField("User name", text: $user)
                SecureField("Password", text: $password)
                Button("Add") {
                    let login = SiteLogin(urlPrefix: prefix, username: user)
                    model.library.secrets.setPassword(password, for: login.credentialKey)
                    model.library.settings.siteLogins.append(login)
                    prefix = ""; user = ""; password = ""
                }
                .disabled(prefix.isEmpty || user.isEmpty)
            }
            Text("Passwords are stored in your Mac's Keychain.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

struct SoundSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            ForEach(SoundEvent.allCases, id: \.self) { event in
                HStack {
                    Toggle(title(event), isOn: Binding(
                        get: { model.library.settings.sounds.enabled.contains(event.rawValue) },
                        set: { on in
                            if on { model.library.settings.sounds.enabled.insert(event.rawValue) } else { model.library.settings.sounds.enabled.remove(event.rawValue) }
                        }
                    ))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { model.library.settings.sounds.sounds[event.rawValue] ?? "Glass" },
                        set: { model.library.settings.sounds.sounds[event.rawValue] = $0 }
                    )) {
                        ForEach(SoundPlayer.systemSounds, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    Button { NSSound(named: NSSound.Name(model.library.settings.sounds.sounds[event.rawValue] ?? "Glass"))?.play() } label: { Image(systemName: "play.circle") }
                        .buttonStyle(.borderless)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func title(_ event: SoundEvent) -> String {
        switch event {
        case .downloadComplete: String(localized: "Download complete")
        case .downloadFailed: String(localized: "Download failed")
        case .queueStarted: String(localized: "Queue started")
        case .queueFinished: String(localized: "Queue finished")
        }
    }
}

struct SpeedLimiterSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Toggle("Limit the total download speed", isOn: model.setting(\.speedLimiter.enabled))
            HStack {
                Text("Maximum speed")
                TextField("", value: Binding(
                    get: { Double(model.library.settings.speedLimiter.bytesPerSecond) / 1024 },
                    set: { model.library.settings.speedLimiter.bytesPerSecond = Int64(max(1, $0) * 1024) }
                ), format: .number).frame(width: 90)
                Text("KB/s")
            }
            Toggle("Always turn the limiter on when cDownloader opens", isOn: model.setting(\.speedLimiter.turnOnAtStartup))
            Text("Each download can also have its own limit, in the details panel under the list. Very low limits can make some servers drop the connection.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

struct BrowserSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var installed = BrowserIntegration.installedBrowsers

    var body: some View {
        Form {
            Section("Browser add-on (Chrome, Edge, Brave and other Chromium browsers)") {
                LabeledContent("Connected browsers", value: installed.isEmpty ? String(localized: "None yet") : installed.joined(separator: ", "))
                Text("1. Open chrome://extensions (or edge://extensions, brave://extensions).\n2. Turn on Developer mode.\n3. Click “Load unpacked” and choose the add-on folder.")
                    .font(.callout)
                HStack {
                    Button("Show Add-on Folder") {
                        if let folder = BrowserIntegration.extensionFolder { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    }
                    .disabled(BrowserIntegration.extensionFolder == nil)
                    Button("Reconnect Browsers") {
                        BrowserIntegration.register()
                        installed = BrowserIntegration.installedBrowsers
                    }
                }
            }
            Section("Download panel on web players") {
                Toggle("Show “Download this video” on videos", isOn: model.setting(\.browser.videoPanelEnabled))
                Stepper("Ignore media smaller than \(model.library.settings.browser.minimumMediaKB) KB", value: model.setting(\.browser.minimumMediaKB), in: 0...10_000, step: 100)
                Text("Don't show the panel on these sites (one per line)")
                TextEditor(text: model.listSetting(\.browser.videoPanelExcludedSites)).font(.body.monospaced()).frame(height: 60)
                Text("Videos protected with DRM are labeled as protected and cannot be downloaded.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// YouTube downloads: whether the tools are installed, the default quality, and where the sign-in comes from.
struct VideoSiteSettings: View {
    @Environment(AppModel.self) private var model

    /// Browsers yt-dlp can read a YouTube sign-in from, by the name it expects.
    private static let browsers: [(name: String, title: String)] = [
        ("chrome", "Chrome"), ("brave", "Brave"), ("edge", "Microsoft Edge"), ("vivaldi", "Vivaldi"), ("safari", "Safari"), ("firefox", "Firefox"),
    ]

    var body: some View {
        Form {
            Section("YouTube") {
                LabeledContent("yt-dlp") {
                    Text(ytDlpStatus).foregroundStyle(.secondary)
                }
                LabeledContent("ffmpeg") {
                    Text(ffmpegStatus).foregroundStyle(.secondary)
                }
                Text("cDownloader comes with yt-dlp, the free tool that does the YouTube downloads, and with ffmpeg, which joins picture and sound into one file. YouTube changes often, so cDownloader looks for a newer yt-dlp once a day by itself.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Downloads") {
                Picker("Default quality", selection: model.setting(\.webVideoQuality)) {
                    ForEach(VideoQuality.allCases, id: \.self) { quality in Text(quality.label).tag(quality) }
                }
                Picker("YouTube sign-in for addresses added here", selection: model.setting(\.webVideoCookiesBrowser)) {
                    Text("None").tag(String?.none)
                    ForEach(Self.browsers, id: \.name) { browser in Text(browser.title).tag(String?.some(browser.name)) }
                }
                Text("Downloads started from the browser add-on use your YouTube sign-in automatically. For addresses added in the app, yt-dlp can read the sign-in from the browser chosen here; macOS may ask for your password the first time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// yt-dlp as found: the app's own copy or the packed one (with its version), Homebrew's, or none.
    private var ytDlpStatus: String {
        guard let path = YtDlp.locate() else { return String(localized: "Missing. Reinstall cDownloader.") }
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL
        let versionFile: URL?
        if folder == AppPaths.toolsDirectory.standardizedFileURL {
            versionFile = AppPaths.toolsDirectory.appendingPathComponent("yt-dlp.version")
        } else if folder == AppPaths.bundledToolsDirectory?.standardizedFileURL {
            versionFile = AppPaths.bundledYtDlpVersionFile
        } else {
            return String(localized: "Installed with Homebrew")
        }
        guard let version = versionFile.flatMap(YtDlpUpdater.version(at:)) else { return String(localized: "Included") }
        return String(localized: "Included, version \(version)")
    }

    private var ffmpegStatus: String {
        guard let path = FFmpeg.locate() else { return String(localized: "Missing. Reinstall cDownloader.") }
        let packed = AppPaths.bundledToolsDirectory.map { path.hasPrefix($0.path + "/") } ?? false
        return packed ? String(localized: "Included") : String(localized: "Installed with Homebrew")
    }
}

extension VideoQuality {
    /// The name shown in pickers.
    var label: String {
        switch self {
        case .best: String(localized: "Best available")
        case .p1080: String(localized: "1080p (Full HD)")
        case .p720: String(localized: "720p (HD)")
        case .p480: String(localized: "480p")
        case .p360: String(localized: "360p (smallest file)")
        case .audio: String(localized: "Sound only (M4A)")
        }
    }
}
