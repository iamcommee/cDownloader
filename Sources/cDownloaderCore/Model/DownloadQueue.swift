import Foundation

public enum QueueKind: String, Codable, Sendable, CaseIterable {
    /// Files leave the queue once they finish.
    case download
    /// Files stay; each run re-downloads the ones that changed on the server.
    case synchronization
}

public struct TimeOfDay: Codable, Sendable, Equatable, Hashable, Comparable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    public var minutesSinceMidnight: Int { hour * 60 + minute }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.minutesSinceMidnight < rhs.minutesSinceMidnight
    }
}

public enum ScheduleRepeat: Codable, Sendable, Equatable {
    /// Only on the calendar day containing this date.
    case once(Date)
    case daily
    /// Calendar weekdays, 1 = Sunday ... 7 = Saturday.
    case weekdays(Set<Int>)
}

public struct QueueSchedule: Codable, Sendable, Equatable {
    public var startEnabled: Bool
    public var startTime: TimeOfDay
    public var repeatRule: ScheduleRepeat
    public var stopEnabled: Bool
    public var stopTime: TimeOfDay
    /// Synchronization queues may run again every N minutes until the stop time or the end of the day.
    public var repeatEveryMinutes: Int?

    public init(
        startEnabled: Bool = false,
        startTime: TimeOfDay = TimeOfDay(hour: 23, minute: 0),
        repeatRule: ScheduleRepeat = .daily,
        stopEnabled: Bool = false,
        stopTime: TimeOfDay = TimeOfDay(hour: 7, minute: 0),
        repeatEveryMinutes: Int? = nil
    ) {
        self.startEnabled = startEnabled
        self.startTime = startTime
        self.repeatRule = repeatRule
        self.stopEnabled = stopEnabled
        self.stopTime = stopTime
        self.repeatEveryMinutes = repeatEveryMinutes
    }
}

public enum PostQueueAction: Codable, Sendable, Equatable {
    case none
    case quitApp
    case sleep
    case shutDown(force: Bool)
    case openFile(String)
}

public struct DownloadQueue: Codable, Sendable, Identifiable, Equatable {
    public static let mainDownloadID = UUID(uuidString: "00000000-0000-0000-0000-00000000D001")!
    public static let mainSyncID = UUID(uuidString: "00000000-0000-0000-0000-00000000D002")!

    public var id: UUID
    public var name: String
    public var kind: QueueKind
    public var concurrentDownloads: Int
    /// Items in processing order.
    public var itemIDs: [UUID]
    public var schedule: QueueSchedule
    /// nil retries forever.
    public var maxRetries: Int?
    public var postAction: PostQueueAction

    public init(
        id: UUID = UUID(),
        name: String,
        kind: QueueKind = .download,
        concurrentDownloads: Int = 2,
        itemIDs: [UUID] = [],
        schedule: QueueSchedule = QueueSchedule(),
        maxRetries: Int? = nil,
        postAction: PostQueueAction = .none
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.concurrentDownloads = concurrentDownloads
        self.itemIDs = itemIDs
        self.schedule = schedule
        self.maxRetries = maxRetries
        self.postAction = postAction
    }

    public var isMain: Bool { id == Self.mainDownloadID || id == Self.mainSyncID }

    public static func defaults() -> [DownloadQueue] {
        [
            DownloadQueue(id: mainDownloadID, name: "Main Download Queue", kind: .download),
            DownloadQueue(id: mainSyncID, name: "Synchronization Queue", kind: .synchronization),
        ]
    }
}
