import cDownloaderCore
import SwiftUI

/// IDM's Scheduler: pick a queue, set when it runs and what happens after, and order its files.
struct SchedulerView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedQueue: UUID? = DownloadQueue.mainDownloadID
    @State private var draft: DownloadQueue?
    @State private var tab = 0

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                List(selection: $selectedQueue) {
                    ForEach(model.library.queues) { queue in
                        HStack {
                            Image(systemName: queue.kind == .download ? "square.stack.3d.down.forward" : "arrow.triangle.2.circlepath")
                            Text(queue.name)
                            Spacer()
                            if model.library.isQueueRunning(queue.id) { Image(systemName: "play.circle.fill").foregroundStyle(.green) }
                        }
                        .tag(queue.id)
                        .dropDestination(for: String.self) { values, _ in
                            let ids = values.compactMap(UUID.init(uuidString:))
                            model.library.moveItems(ids, toQueue: queue.id)
                            return !ids.isEmpty
                        }
                    }
                }
                HStack {
                    Button { selectedQueue = model.library.addQueue(name: String(localized: "New Queue"), kind: .download).id } label: { Image(systemName: "plus") }
                    Button {
                        if let id = selectedQueue { model.library.deleteQueue(id); selectedQueue = DownloadQueue.mainDownloadID }
                    } label: { Image(systemName: "minus") }
                    .disabled(model.library.queues.first { $0.id == selectedQueue }?.isMain ?? true)
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 200, maxWidth: 260)

            VStack(spacing: 0) {
                if let binding = draftBinding {
                    TabView(selection: $tab) {
                        ScheduleTab(queue: binding).tabItem { Text("Schedule") }.tag(0)
                        QueueFilesTab(queue: binding).tabItem { Text("Files in the Queue") }.tag(1)
                    }
                    .padding()
                    Divider()
                    HStack {
                        let running = model.library.isQueueRunning(binding.wrappedValue.id)
                        Button("Start Now") { apply(); model.library.startQueue(binding.wrappedValue.id) }.disabled(running)
                        Button("Stop") { model.library.stopQueue(binding.wrappedValue.id) }.disabled(!running)
                        Spacer()
                        Button("Apply") { apply() }.keyboardShortcut(.defaultAction)
                    }
                    .padding()
                } else {
                    ContentUnavailableView("Choose a queue", systemImage: "calendar")
                }
            }
            .frame(minWidth: 520)
        }
        .onAppear { loadDraft() }
        .onChange(of: selectedQueue) { old, _ in
            if let old, draft?.id == old { apply() }
            loadDraft()
        }
        .onDisappear { apply() }
    }

    private var draftBinding: Binding<DownloadQueue>? {
        guard draft != nil else { return nil }
        return Binding(get: { draft! }, set: { draft = $0 })
    }

    private func loadDraft() {
        draft = model.library.queues.first { $0.id == selectedQueue }
    }

    /// Order changes are saved at once; other changes on Apply, when switching queues or closing.
    private func apply() {
        guard var draft else { return }
        if let current = model.library.queues.first(where: { $0.id == draft.id }) { draft.itemIDs = current.itemIDs }
        model.library.updateQueue(draft)
        self.draft = draft
    }
}

struct ScheduleTab: View {
    @Binding var queue: DownloadQueue
    @State private var retriesOn = false

    private static let weekdays: [(Int, String)] = Calendar.current.shortWeekdaySymbols.enumerated().map { ($0.offset + 1, $0.element) }

    var body: some View {
        Form {
            Section {
                TextField("Queue name", text: $queue.name).disabled(queue.isMain)
                Picker("Queue type", selection: $queue.kind) {
                    Text("One-time downloading").tag(QueueKind.download)
                    Text("Periodic synchronization").tag(QueueKind.synchronization)
                }
                .disabled(queue.isMain)
            }
            Section("Start") {
                Toggle("Start download at", isOn: $queue.schedule.startEnabled)
                if queue.schedule.startEnabled {
                    DatePicker("Time", selection: timeBinding(\.startTime), displayedComponents: .hourAndMinute)
                    Picker("Days", selection: repeatKind) {
                        Text("Once").tag(0)
                        Text("Daily").tag(1)
                        Text("On these days").tag(2)
                    }
                    if case .once(let day) = queue.schedule.repeatRule {
                        DatePicker("Date", selection: Binding(get: { day }, set: { queue.schedule.repeatRule = .once($0) }), displayedComponents: .date)
                    }
                    if case .weekdays(let days) = queue.schedule.repeatRule {
                        HStack {
                            ForEach(Self.weekdays, id: \.0) { number, name in
                                Toggle(name, isOn: Binding(
                                    get: { days.contains(number) },
                                    set: { on in
                                        var set = days
                                        if on { set.insert(number) } else { set.remove(number) }
                                        queue.schedule.repeatRule = .weekdays(set)
                                    }
                                ))
                                .toggleStyle(.button)
                            }
                        }
                    }
                    if queue.kind == .synchronization {
                        Stepper(
                            "Repeat every \(queue.schedule.repeatEveryMinutes ?? 0) minutes",
                            value: Binding(get: { queue.schedule.repeatEveryMinutes ?? 0 }, set: { queue.schedule.repeatEveryMinutes = $0 == 0 ? nil : $0 }),
                            in: 0...1440, step: 15
                        )
                    }
                }
            }
            Section("Stop") {
                Toggle("Stop download at", isOn: $queue.schedule.stopEnabled)
                if queue.schedule.stopEnabled {
                    DatePicker("Time", selection: timeBinding(\.stopTime), displayedComponents: .hourAndMinute)
                }
            }
            Section("Retries and files at once") {
                Stepper("Download \(queue.concurrentDownloads) files at the same time", value: $queue.concurrentDownloads, in: 1...16)
                Toggle("Limit retries for files that fail", isOn: Binding(get: { queue.maxRetries != nil }, set: { queue.maxRetries = $0 ? 3 : nil }))
                if let retries = queue.maxRetries {
                    Stepper("Retry each file \(retries) times", value: Binding(get: { retries }, set: { queue.maxRetries = $0 }), in: 1...100)
                }
            }
            Section("When the queue is done") {
                Picker("Then", selection: postActionKind) {
                    Text("Do nothing").tag(0)
                    Text("Quit cDownloader").tag(1)
                    Text("Put the Mac to sleep").tag(2)
                    Text("Shut down the Mac").tag(3)
                    Text("Open a file").tag(4)
                }
                if case .openFile(let path) = queue.postAction {
                    HStack {
                        TextField("File to open", text: Binding(get: { path }, set: { queue.postAction = .openFile($0) }))
                        Button("Choose…") { if let file = FolderPicker.chooseFile() { queue.postAction = .openFile(file.path) } }
                    }
                }
                Text("These actions don't run when you stop the queue yourself.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func timeBinding(_ keyPath: WritableKeyPath<QueueSchedule, TimeOfDay>) -> Binding<Date> {
        Binding(
            get: {
                let time = queue.schedule[keyPath: keyPath]
                return Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                queue.schedule[keyPath: keyPath] = TimeOfDay(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
            }
        )
    }

    private var repeatKind: Binding<Int> {
        Binding(
            get: {
                switch queue.schedule.repeatRule {
                case .once: 0
                case .daily: 1
                case .weekdays: 2
                }
            },
            set: { kind in
                switch kind {
                case 0: queue.schedule.repeatRule = .once(Date())
                case 1: queue.schedule.repeatRule = .daily
                default: queue.schedule.repeatRule = .weekdays([2, 3, 4, 5, 6])
                }
            }
        )
    }

    private var postActionKind: Binding<Int> {
        Binding(
            get: {
                switch queue.postAction {
                case .none: 0
                case .quitApp: 1
                case .sleep: 2
                case .shutDown: 3
                case .openFile: 4
                }
            },
            set: { kind in
                queue.postAction = [.none, .quitApp, .sleep, .shutDown(force: false), .openFile("")][kind]
            }
        )
    }
}

struct QueueFilesTab: View {
    @Binding var queue: DownloadQueue
    @Environment(AppModel.self) private var model
    @State private var selection: Set<UUID> = []

    private var ids: [UUID] { model.library.queues.first { $0.id == queue.id }?.itemIDs ?? [] }

    var body: some View {
        VStack(alignment: .leading) {
            List(selection: $selection) {
                ForEach(ids, id: \.self) { id in
                    if let item = model.library.item(id) {
                        HStack {
                            Text(item.fileName.isEmpty ? item.url.lastPathComponent : item.fileName).lineLimit(1)
                            Spacer()
                            Text(Format.bytes(item.totalBytes)).foregroundStyle(.secondary).monospacedDigit()
                            Text(Format.status(item, progress: model.library.progress[id])).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                        }
                        .draggable(id.uuidString)
                    }
                }
                .onMove { from, to in
                    var order = ids
                    order.move(fromOffsets: from, toOffset: to)
                    model.library.moveItems(order, toQueue: queue.id)
                }
            }
            HStack {
                Button { move(-1) } label: { Image(systemName: "arrow.up") }.disabled(selection.isEmpty)
                Button { move(1) } label: { Image(systemName: "arrow.down") }.disabled(selection.isEmpty)
                Button("Remove from Queue") { model.library.moveItems(Array(selection), toQueue: nil); selection = [] }.disabled(selection.isEmpty)
                Spacer()
                Text("Drag files onto another queue on the left to move them.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func move(_ step: Int) {
        var order = ids
        let indices = order.indices.filter { selection.contains(order[$0]) }
        let ordered = step < 0 ? indices : indices.reversed()
        for index in ordered {
            let target = index + step
            guard order.indices.contains(target), !selection.contains(order[target]) else { continue }
            order.swapAt(index, target)
        }
        model.library.moveItems(order, toQueue: queue.id)
    }
}
