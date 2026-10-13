import Foundation
import Testing
@testable import cDownloaderCore

/// Records what the runner asks the app to do.
final class FakeQueueHost: @unchecked Sendable {
    var started: [UUID] = []
    var stopped: [UUID] = []
    var postActions: [PostQueueAction] = []
    var statuses: [UUID: DownloadStatus] = [:]
    var remoteChanged: [UUID: Bool] = [:]
    var checked: [UUID] = []
    var latestQueues: [DownloadQueue] = []

    func attach(_ runner: QueueRunner) {
        runner.startDownload = { [unowned self] in started.append($0); statuses[$0] = .downloading }
        runner.stopDownload = { [unowned self] in stopped.append($0) }
        runner.performPostAction = { [unowned self] in postActions.append($0.postAction) }
        runner.itemStatus = { [unowned self] in statuses[$0] }
        runner.checkRemoteChanged = { [unowned self] id, reply in
            checked.append(id)
            reply(remoteChanged[id] ?? false)
        }
        runner.queuesChanged = { [unowned self] in latestQueues = $0 }
    }
}

@Suite struct QueueSchedulerTests {
    let ids = (0..<5).map { _ in UUID() }

    func makeRunner(kind: QueueKind = .download, concurrent: Int = 2, maxRetries: Int? = nil, postAction: PostQueueAction = .none, items: [UUID]? = nil) -> (QueueRunner, FakeQueueHost, DownloadQueue, TestClock) {
        let clock = TestClock()
        let queue = DownloadQueue(name: "Q", kind: kind, concurrentDownloads: concurrent, itemIDs: items ?? ids, maxRetries: maxRetries, postAction: postAction)
        let runner = QueueRunner(queues: DownloadQueue.defaults() + [queue], clock: clock)
        let host = FakeQueueHost()
        host.attach(runner)
        return (runner, host, queue, clock)
    }

    // MARK: T8-01

    @Test func t8_01_runsNFilesAtOnceInListOrder() {
        let (runner, host, queue, _) = makeRunner(concurrent: 2)
        runner.start(queue.id)
        #expect(host.started == [ids[0], ids[1]])
        #expect(runner.activeItems(in: queue.id) == [ids[0], ids[1]])
        host.statuses[ids[1]] = .completed
        runner.downloadFinished(ids[1], outcome: .completed)
        #expect(host.started == [ids[0], ids[1], ids[2]])
        #expect(runner.activeItems(in: queue.id).count == 2)
    }

    @Test func t8_01_manualStopStopsDownloadsWithoutPostAction() {
        let (runner, host, queue, _) = makeRunner(concurrent: 2, postAction: .sleep)
        runner.start(queue.id)
        runner.stop(queue.id)
        #expect(Set(host.stopped) == [ids[0], ids[1]])
        #expect(!runner.isRunning(queue.id))
        runner.downloadFinished(ids[0], outcome: .stopped)
        #expect(host.postActions.isEmpty)
    }

    // MARK: T8-02

    @Test func t8_02_failedFileMovesToEndWhileOthersProceed() {
        let (runner, host, queue, _) = makeRunner(concurrent: 1)
        runner.start(queue.id)
        host.statuses[ids[0]] = .failed
        runner.downloadFinished(ids[0], outcome: .failed)
        #expect(host.started == [ids[0], ids[1]])
        #expect(runner.queues.first { $0.id == queue.id }?.itemIDs.last == ids[0])
        #expect(host.latestQueues.first { $0.id == queue.id }?.itemIDs == [ids[1], ids[2], ids[3], ids[4], ids[0]])
    }

    @Test func t8_02_soleFailingFileIsRetriedEvery30Seconds() {
        let (runner, host, queue, clock) = makeRunner(concurrent: 1, items: [ids[0]])
        runner.start(queue.id)
        host.statuses[ids[0]] = .failed
        runner.downloadFinished(ids[0], outcome: .failed)
        #expect(host.started == [ids[0]])
        clock.advance(29)
        runner.tick()
        #expect(host.started == [ids[0]])
        clock.advance(1)
        runner.tick()
        #expect(host.started == [ids[0], ids[0]])
        #expect(runner.isRunning(queue.id))
    }

    @Test func t8_02_maxRetriesGivesUpAndQueueEnds() {
        let (runner, host, queue, clock) = makeRunner(concurrent: 1, maxRetries: 2, postAction: .quitApp, items: [ids[0]])
        runner.start(queue.id)
        for _ in 0..<3 {
            host.statuses[ids[0]] = .failed
            runner.downloadFinished(ids[0], outcome: .failed)
            clock.advance(30)
            runner.tick()
        }
        #expect(host.started.count == 3)
        #expect(!runner.isRunning(queue.id))
        #expect(host.postActions == [.quitApp])
    }

    @Test func t8_02_unlimitedRetriesKeepGoing() {
        let (runner, host, queue, clock) = makeRunner(concurrent: 1, maxRetries: nil, items: [ids[0]])
        runner.start(queue.id)
        for _ in 0..<10 {
            host.statuses[ids[0]] = .failed
            runner.downloadFinished(ids[0], outcome: .failed)
            clock.advance(30)
            runner.tick()
        }
        #expect(host.started.count == 11)
        #expect(runner.isRunning(queue.id))
    }

    // MARK: T8-03

    @Test func t8_03_completedFileLeavesDownloadQueueButStaysInSyncQueue() {
        let (runner, host, queue, _) = makeRunner(kind: .download, concurrent: 1, items: [ids[0], ids[1]])
        runner.start(queue.id)
        host.statuses[ids[0]] = .completed
        runner.downloadFinished(ids[0], outcome: .completed)
        #expect(runner.queues.first { $0.id == queue.id }?.itemIDs == [ids[1]])

        let (syncRunner, syncHost, syncQueue, _) = makeRunner(kind: .synchronization, concurrent: 1, items: [ids[0], ids[1]])
        syncRunner.start(syncQueue.id)
        syncHost.statuses[ids[0]] = .completed
        syncRunner.downloadFinished(ids[0], outcome: .completed)
        #expect(syncRunner.queues.first { $0.id == syncQueue.id }?.itemIDs == [ids[0], ids[1]])
    }

    struct SyncRow: Sendable, CustomTestStringConvertible {
        var label: String
        var changed: Bool
        var testDescription: String { label }
    }

    @Test(arguments: [
        SyncRow(label: "unchanged", changed: false),
        SyncRow(label: "changed", changed: true),
    ])
    func t8_03_syncQueueRedownloadsOnlyChangedFiles(row: SyncRow) {
        let (runner, host, queue, _) = makeRunner(kind: .synchronization, concurrent: 1, items: [ids[0]])
        host.statuses[ids[0]] = .completed
        host.remoteChanged[ids[0]] = row.changed
        runner.start(queue.id)
        #expect(host.checked == [ids[0]])
        #expect(host.started == (row.changed ? [ids[0]] : []))
        if !row.changed { #expect(!runner.isRunning(queue.id)) }
    }

    struct ChangeRow: Sendable, CustomTestStringConvertible {
        var label: String
        var remote: RemoteFileInfo
        var changed: Bool
        var testDescription: String { label }
    }

    @Test(arguments: [
        ChangeRow(label: "unchanged", remote: RemoteFileInfo(size: 100, lastModified: "A", etag: "e"), changed: false),
        ChangeRow(label: "size", remote: RemoteFileInfo(size: 101, lastModified: "A", etag: "e"), changed: true),
        ChangeRow(label: "mtime", remote: RemoteFileInfo(size: 100, lastModified: "B", etag: "e"), changed: true),
        ChangeRow(label: "etag", remote: RemoteFileInfo(size: 100, lastModified: "A", etag: "f"), changed: true),
        ChangeRow(label: "unknown remote", remote: RemoteFileInfo(size: nil, lastModified: nil, etag: nil), changed: false),
    ])
    func t8_03_changeDetection(row: ChangeRow) {
        var item = DownloadItem(url: URL(string: "https://h/f")!, fileName: "f", directory: "/tmp")
        item.totalBytes = 100
        item.lastModified = "A"
        item.etag = "e"
        #expect(RemoteFileInfo.hasChanged(item: item, remote: row.remote) == row.changed)
    }

    @Test func t8_03_defaultQueuesExistAndCustomQueuesCanBeAdded() {
        let defaults = DownloadQueue.defaults()
        #expect(defaults.map(\.kind) == [.download, .synchronization])
        #expect(defaults.allSatisfy { $0.isMain })
        let (runner, host, queue, _) = makeRunner(concurrent: 1, items: [ids[0]])
        runner.start(queue.id)
        #expect(host.started == [ids[0]])
    }

    // MARK: T8-04

    @Test func t8_04_postActionFiresOnceWhenQueueFinishesOnItsOwn() {
        let (runner, host, queue, _) = makeRunner(concurrent: 2, postAction: .shutDown(force: false), items: [ids[0], ids[1]])
        runner.start(queue.id)
        host.statuses[ids[0]] = .completed
        runner.downloadFinished(ids[0], outcome: .completed)
        #expect(host.postActions.isEmpty)
        host.statuses[ids[1]] = .completed
        runner.downloadFinished(ids[1], outcome: .completed)
        #expect(host.postActions == [.shutDown(force: false)])
        runner.tick()
        #expect(host.postActions.count == 1)
    }

    @Test func t8_04_emptyQueueFiresNothing() {
        let (runner, host, queue, _) = makeRunner(concurrent: 2, postAction: .openFile("/tmp/x"), items: [])
        runner.start(queue.id)
        #expect(host.postActions.isEmpty)
        #expect(!runner.isRunning(queue.id))
    }

    // MARK: T8-05

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func date(_ text: String, _ calendar: Calendar = utc) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    struct ScheduleRow: Sendable, CustomTestStringConvertible {
        var label: String
        var schedule: QueueSchedule
        var after: String
        var expectedStart: String?
        var testDescription: String { label }
    }

    // 2026-03-02 is a Monday.
    @Test(arguments: [
        ScheduleRow(label: "once future", schedule: QueueSchedule(startEnabled: true, startTime: .init(hour: 10, minute: 0), repeatRule: .once(QueueSchedulerTests.date("2026-03-05 00:00"))), after: "2026-03-02 12:00", expectedStart: "2026-03-05 10:00"),
        ScheduleRow(label: "once past", schedule: QueueSchedule(startEnabled: true, startTime: .init(hour: 10, minute: 0), repeatRule: .once(QueueSchedulerTests.date("2026-03-01 00:00"))), after: "2026-03-02 12:00", expectedStart: nil),
        ScheduleRow(label: "daily later today", schedule: QueueSchedule(startEnabled: true, startTime: .init(hour: 8, minute: 0), repeatRule: .daily), after: "2026-03-02 07:59", expectedStart: "2026-03-02 08:00"),
        ScheduleRow(label: "daily across midnight", schedule: QueueSchedule(startEnabled: true, startTime: .init(hour: 8, minute: 0), repeatRule: .daily), after: "2026-03-02 23:30", expectedStart: "2026-03-03 08:00"),
        ScheduleRow(label: "weekdays skip", schedule: QueueSchedule(startEnabled: true, startTime: .init(hour: 8, minute: 0), repeatRule: .weekdays([2, 4])), after: "2026-03-02 09:00", expectedStart: "2026-03-04 08:00"),
        ScheduleRow(label: "start disabled", schedule: QueueSchedule(startEnabled: false, startTime: .init(hour: 8, minute: 0), repeatRule: .daily), after: "2026-03-02 07:00", expectedStart: nil),
        ScheduleRow(label: "sync repeat", schedule: QueueSchedule(startEnabled: true, startTime: .init(hour: 8, minute: 0), repeatRule: .daily, stopEnabled: true, stopTime: .init(hour: 9, minute: 0), repeatEveryMinutes: 30), after: "2026-03-02 08:00", expectedStart: "2026-03-02 08:30"),
        ScheduleRow(label: "sync repeat stops before stop time", schedule: QueueSchedule(startEnabled: true, startTime: .init(hour: 8, minute: 0), repeatRule: .daily, stopEnabled: true, stopTime: .init(hour: 9, minute: 0), repeatEveryMinutes: 30), after: "2026-03-02 08:30", expectedStart: "2026-03-03 08:00"),
        ScheduleRow(label: "repeat until end of day", schedule: QueueSchedule(startEnabled: true, startTime: .init(hour: 23, minute: 0), repeatRule: .once(QueueSchedulerTests.date("2026-03-02 00:00")), repeatEveryMinutes: 30), after: "2026-03-02 23:30", expectedStart: nil),
        ScheduleRow(label: "repeat late evening", schedule: QueueSchedule(startEnabled: true, startTime: .init(hour: 23, minute: 0), repeatRule: .once(QueueSchedulerTests.date("2026-03-02 00:00")), repeatEveryMinutes: 30), after: "2026-03-02 23:00", expectedStart: "2026-03-02 23:30"),
    ])
    func t8_05_nextStart(row: ScheduleRow) {
        let result = QueueScheduler.nextStart(after: Self.date(row.after), schedule: row.schedule, calendar: Self.utc)
        #expect(result == row.expectedStart.map { Self.date($0) })
    }

    @Test func t8_05_stopTimeAppliesWithOrWithoutStart() {
        let withStart = QueueSchedule(startEnabled: true, startTime: .init(hour: 8, minute: 0), repeatRule: .daily, stopEnabled: true, stopTime: .init(hour: 10, minute: 0))
        #expect(QueueScheduler.nextStop(after: Self.date("2026-03-02 09:00"), schedule: withStart, calendar: Self.utc) == Self.date("2026-03-02 10:00"))
        let stopOnly = QueueSchedule(startEnabled: false, stopEnabled: true, stopTime: .init(hour: 10, minute: 0))
        #expect(QueueScheduler.nextStop(after: Self.date("2026-03-02 10:30"), schedule: stopOnly, calendar: Self.utc) == Self.date("2026-03-03 10:00"))
        let noStop = QueueSchedule(stopEnabled: false)
        #expect(QueueScheduler.nextStop(after: Self.date("2026-03-02 10:30"), schedule: noStop, calendar: Self.utc) == nil)
    }

    @Test func t8_05_daylightSavingGapFiresOnce() throws {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        // 2026-03-29 02:00 -> 03:00 in Berlin, so 02:30 does not exist that day.
        let schedule = QueueSchedule(startEnabled: true, startTime: .init(hour: 2, minute: 30), repeatRule: .daily)
        let before = Self.date("2026-03-29 00:00", berlin)
        let first = try #require(QueueScheduler.nextStart(after: before, schedule: schedule, calendar: berlin))
        #expect(berlin.isDate(first, inSameDayAs: before))
        let second = try #require(QueueScheduler.nextStart(after: first, schedule: schedule, calendar: berlin))
        #expect(!berlin.isDate(second, inSameDayAs: before))
    }

    @Test func t8_05_runnerStartsAndStopsQueuesOnSchedule() {
        let clock = TestClock(Self.date("2026-03-02 07:59"))
        var queue = DownloadQueue(name: "Night", concurrentDownloads: 1, itemIDs: [ids[0], ids[1]], postAction: .sleep)
        queue.schedule = QueueSchedule(startEnabled: true, startTime: .init(hour: 8, minute: 0), repeatRule: .daily, stopEnabled: true, stopTime: .init(hour: 9, minute: 0))
        let runner = QueueRunner(queues: [queue], clock: clock, calendar: Self.utc)
        let host = FakeQueueHost()
        host.attach(runner)
        runner.tick()
        #expect(host.started.isEmpty)
        clock.advance(60)
        runner.tick()
        #expect(host.started == [ids[0]])
        clock.advance(3600)
        runner.tick()
        #expect(!runner.isRunning(queue.id))
        #expect(host.stopped == [ids[0]])
        #expect(host.postActions.isEmpty)
    }
}
