import cDownloaderCore
import SwiftUI

/// The four-step site grabber, plus the results list.
struct GrabberWizard: View {
    let projectID: UUID?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var project: GrabberProject?
    @State private var step = 1
    @State private var startAddress = ""
    @State private var templateName = GrabberTemplate.all[0].name
    @State private var fileTypesText = ""
    @State private var listsText: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ForEach(1...5, id: \.self) { number in
                    Text(stepTitle(number))
                        .font(.caption.weight(number == step ? .bold : .regular))
                        .foregroundStyle(number == step ? Color.accentColor : .secondary)
                    if number < 5 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                }
            }
            .padding(10)
            Divider()
            Group {
                if let binding = projectBinding {
                    switch step {
                    case 1: stepOne(binding)
                    case 2: stepTwo(binding)
                    case 3: stepThree(binding)
                    case 4: stepFour(binding)
                    default: GrabberResults(project: binding)
                    }
                } else {
                    stepOneStart
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                Button("Close") { saveAndClose() }
                Spacer()
                if step > 1 { Button("Back") { step -= 1 } }
                if step < 4 {
                    Button("Next") { advance() }.keyboardShortcut(.defaultAction).disabled(project == nil && URL(string: startAddress)?.host == nil)
                } else if step == 4 {
                    Button("Explore the Site") {
                        commitLists()
                        if let project { model.runGrabber(project) }
                        step = 5
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
        .frame(minWidth: 760, minHeight: 540)
        .onAppear(perform: load)
    }

    private var projectBinding: Binding<GrabberProject>? {
        guard project != nil else { return nil }
        return Binding(get: { project! }, set: { project = $0 })
    }

    private func stepTitle(_ number: Int) -> String {
        switch number {
        case 1: String(localized: "1. Start page")
        case 2: String(localized: "2. Save to")
        case 3: String(localized: "3. Pages to explore")
        case 4: String(localized: "4. Files to download")
        default: String(localized: "Results")
        }
    }

    private func load() {
        if let projectID, let existing = model.grabberProjects.first(where: { $0.id == projectID }) {
            project = existing
            step = 5
        }
    }

    private var stepOneStart: some View {
        Form {
            Section("Where should the grabber start?") {
                TextField("Start page address", text: $startAddress, prompt: Text("https://example.com/gallery/"))
                Picker("Project template", selection: $templateName) {
                    ForEach(GrabberTemplate.all) { template in Text(template.name).tag(template.name) }
                }
            }
            Text("The grabber reads pages of a web site and lists the files that match your filters, so you can download them all at once.")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private func stepOne(_ project: Binding<GrabberProject>) -> some View {
        Form {
            TextField("Project name", text: project.name)
            TextField("Start page", text: Binding(
                get: { project.wrappedValue.settings.startURL.absoluteString },
                set: { if let url = URL(string: $0), url.host != nil { project.wrappedValue.settings.startURL = url } }
            ))
            LabeledContent("Template", value: project.wrappedValue.settings.templateName)
        }
        .formStyle(.grouped)
    }

    private func stepTwo(_ project: Binding<GrabberProject>) -> some View {
        Form {
            HStack {
                TextField("Save files to", text: project.settings.saveFolder)
                Button("Choose…") { if let folder = FolderPicker.choose(start: project.wrappedValue.settings.saveFolder) { project.wrappedValue.settings.saveFolder = folder } }
            }
            Toggle("Keep the site's folder structure", isOn: project.settings.useOriginalSubfolders)
            Text("With the folder structure kept, a file from …/photos/2024/a.jpg is saved under photos/2024/.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private func stepThree(_ project: Binding<GrabberProject>) -> some View {
        Form {
            Section("How deep to go") {
                Stepper("Levels of pages on this site: \(project.wrappedValue.settings.levelsOnThisSite)", value: project.settings.levelsOnThisSite, in: 1...50)
                Stepper("Levels of pages on other sites: \(project.wrappedValue.settings.levelsOnOtherSites)", value: project.settings.levelsOnOtherSites, in: 0...5)
                Text("Level 1 reads only the start page. Level 2 also reads the pages it links to, and so on.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Limits") {
                Toggle("Don't explore parent folders", isOn: project.settings.dontExploreParentDirectories)
                Toggle("Explore all sites within the main domain", isOn: project.settings.exploreWholeMainDomain)
            }
            Section("Advanced (use * as a wildcard, one pattern per line)") {
                listEditor("Only explore pages matching", key: "exploreInclude")
                listEditor("Never explore pages matching", key: "exploreExclude")
                listEditor("Log-out pages to avoid", key: "logoutPatterns")
            }
        }
        .formStyle(.grouped)
    }

    private func stepFour(_ project: Binding<GrabberProject>) -> some View {
        Form {
            Section("File types") {
                TextField("Extensions (separated by spaces; * for all files)", text: $fileTypesText)
            }
            Section("Filters (use * as a wildcard, one pattern per line)") {
                listEditor("Only files matching", key: "fileInclude")
                listEditor("Skip files matching", key: "fileExclude")
                HStack {
                    TextField("Minimum size (KB)", value: Binding(
                        get: { project.wrappedValue.settings.minimumSize.map { $0 / 1024 } },
                        set: { project.wrappedValue.settings.minimumSize = $0.map { $0 * 1024 } }
                    ), format: .number)
                    TextField("Maximum size (KB)", value: Binding(
                        get: { project.wrappedValue.settings.maximumSize.map { $0 / 1024 } },
                        set: { project.wrappedValue.settings.maximumSize = $0.map { $0 * 1024 } }
                    ), format: .number)
                }
            }
            Section {
                Toggle("Only files on this site", isOn: project.settings.filesOnThisSiteOnly)
                Toggle("Hide duplicates (same name and size)", isOn: project.settings.hideDuplicates)
                Toggle("Download all found files right away", isOn: project.settings.downloadAllAtOnce)
            }
        }
        .formStyle(.grouped)
    }

    private func listEditor(_ title: LocalizedStringKey, key: String) -> some View {
        VStack(alignment: .leading) {
            Text(title)
            TextEditor(text: Binding(get: { listsText[key] ?? "" }, set: { listsText[key] = $0 }))
                .font(.body.monospaced())
                .frame(height: 54)
        }
    }

    private func advance() {
        if project == nil {
            guard let url = URL(string: startAddress.trimmingCharacters(in: .whitespaces)), url.host != nil else { return }
            let template = GrabberTemplate.all.first { $0.name == templateName } ?? GrabberTemplate.all[0]
            let folder = (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()) + "/" + (url.host ?? "Grabber")
            var settings = GrabberSettings(startURL: url, saveFolder: folder, fileTypes: template.fileTypes, templateName: template.name)
            settings.levelsOnThisSite = template.levelsOnThisSite
            project = GrabberProject(name: url.host ?? "Grabber project", settings: settings)
        }
        if step == 2 { loadLists() }
        if step == 3 { commitLists(); loadLists() }
        step += 1
    }

    private func loadLists() {
        guard let settings = project?.settings else { return }
        fileTypesText = settings.fileTypes.joined(separator: " ")
        listsText = [
            "exploreInclude": settings.exploreInclude.joined(separator: "\n"),
            "exploreExclude": settings.exploreExclude.joined(separator: "\n"),
            "logoutPatterns": settings.logoutPatterns.joined(separator: "\n"),
            "fileInclude": settings.fileInclude.joined(separator: "\n"),
            "fileExclude": settings.fileExclude.joined(separator: "\n"),
        ]
    }

    private func commitLists() {
        guard var settings = project?.settings, !listsText.isEmpty else { return }
        func lines(_ key: String) -> [String] {
            (listsText[key] ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        settings.exploreInclude = lines("exploreInclude")
        settings.exploreExclude = lines("exploreExclude")
        settings.logoutPatterns = lines("logoutPatterns")
        settings.fileInclude = lines("fileInclude")
        settings.fileExclude = lines("fileExclude")
        if !fileTypesText.isEmpty {
            settings.fileTypes = fileTypesText.lowercased().split(whereSeparator: { $0 == " " || $0 == "," }).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        }
        project?.settings = settings
    }

    private func saveAndClose() {
        commitLists()
        if let project { model.saveGrabberProject(project) }
        dismiss()
    }
}

struct GrabberResults: View {
    @Binding var project: GrabberProject
    @Environment(AppModel.self) private var model
    @State private var scheduleOn = false

    var body: some View {
        let current = model.grabberProjects.first { $0.id == project.id } ?? project
        VStack(alignment: .leading, spacing: 8) {
            if model.isGrabbing(project.id) {
                let progress = model.grabberProgress[project.id]
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Explored \(progress?.pagesExplored ?? 0) pages, found \(progress?.filesFound ?? 0) files")
                    Spacer()
                    Button("Stop") { model.stopGrabber(project.id) }
                }
                if let url = progress?.currentURL { Text(url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            } else {
                HStack {
                    Text("\(current.files.count) files found on \(current.pagesExplored) pages").font(.headline)
                    Spacer()
                    Button("Explore Again") { model.runGrabber(project) }
                }
            }
            Table(current.files) {
                TableColumn("") { file in
                    Toggle("", isOn: Binding(
                        get: { file.checked },
                        set: { checked in toggle(file, checked) }
                    ))
                    .labelsHidden()
                }
                .width(24)
                TableColumn("File") { Text($0.relativePath).lineLimit(1).truncationMode(.middle) }
                TableColumn("Size") { Text(Format.bytes($0.size)).monospacedDigit() }.width(80)
                TableColumn("Address") { Text($0.url.absoluteString).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            HStack {
                Button("Check All") { setAll(true) }
                Button("Uncheck All") { setAll(false) }
                Spacer()
                Toggle("Run daily at 3:00", isOn: $scheduleOn)
                    .onChange(of: scheduleOn) { _, on in
                        var updated = current
                        updated.schedule = on ? QueueSchedule(startEnabled: true, startTime: TimeOfDay(hour: 3, minute: 0), repeatRule: .daily) : nil
                        model.saveGrabberProject(updated)
                    }
                Button("Download Checked Files") { model.downloadGrabberFiles(current) }
                    .disabled(!current.files.contains { $0.checked })
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .onAppear { scheduleOn = current.schedule != nil }
    }

    private func toggle(_ file: GrabberFile, _ checked: Bool) {
        guard var updated = model.grabberProjects.first(where: { $0.id == project.id }),
              let index = updated.files.firstIndex(where: { $0.url == file.url })
        else { return }
        updated.files[index].checked = checked
        model.saveGrabberProject(updated)
    }

    private func setAll(_ checked: Bool) {
        guard var updated = model.grabberProjects.first(where: { $0.id == project.id }) else { return }
        for index in updated.files.indices { updated.files[index].checked = checked }
        model.saveGrabberProject(updated)
    }
}
