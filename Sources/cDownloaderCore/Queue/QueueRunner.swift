import Foundation

/// Runs download and synchronization queues: picks the next files, applies retry rules,
/// follows the scheduler and fires the "when done" action.
/// The app calls `tick()` about once a second and `downloadFinished` when a job ends.
public final class QueueRunner: @unchecked Sendable {
    public enum Outcome: Sendable {
        case completed
        case failed
        /// The user stopped this download.
        case stopped
    }

    public static let retryInterval: TimeInterval = 30

    /// Starts a download job for an item.
    public var startDownload: (UUID) -> Void = { _ in }
    /// Stops a running job.
    public var stopDownload: (UUID) -> Void = { _ in }
    /// Synchronization queues: asks whether the server copy changed; reply true to re-download.
    public var checkRemoteChanged: (UUID, @escaping @Sendable (Bool) -> Void) -> Void = { _, reply in reply(true) }
    /// Runs the queue's "when done" action.
    public var performPostAction: (DownloadQueue) -> Void = { _ in }
    /// Queue contents changed (finished files removed, failed files moved to the end).
    public var queuesChanged: ([DownloadQueue]) -> Void = { _ in }
    /// Current status of an item, used to skip finished files.
    public var itemStatus: (UUID) -> DownloadStatus? = { _ in nil }

    public private(set) var queues: [DownloadQueue]
    private let clock: TimeSource
    private let calendar: Calendar

    public init(queues: [DownloadQueue], clock: TimeSource = SystemTimeSource(), calendar: Calendar = .current) {
        self.queues = queues
        self.clock = clock
        self.calendar = calendar
    }

    public func setQueues(_ queues: [DownloadQueue]) {
        self.queues = queues
    }

    private struct RunState {
        var active: Set<UUID> = []
        var checking: Set<UUID> = []
        /// Finished for this run: downloaded, unchanged, stopped by the user or given up.
        var done: Set<UUID> = []
        var retryAt: [UUID: Date] = [:]
        var failures: [UUID: Int] = [:]
        var hadWork = false
    }

    private var runs: [UUID: RunState] = [:]
    private var lastTick: Date?

    private func queue(_ id: UUID) -> DownloadQueue? { queues.first { $0.id == id } }

    private func updateQueue(_ id: UUID, _ change: (inout DownloadQueue) -> Void) {
        guard let index = queues.firstIndex(where: { $0.id == id }) else { return }
        change(&queues[index])
        queuesChanged(queues)
    }

    public func isRunning(_ queueID: UUID) -> Bool { runs[queueID] != nil }

    /// Items of this queue that are downloading or being checked right now.
    public func activeItems(in queueID: UUID) -> Set<UUID> {
        guard let run = runs[queueID] else { return [] }
        return run.active.union(run.checking)
    }

    public func start(_ queueID: UUID) {
        guard runs[queueID] == nil, queue(queueID) != nil else { return }
        runs[queueID] = RunState()
        fill(queueID)
        checkFinished(queueID)
    }

    /// Manual stop: running downloads stop and the "when done" action does not run.
    public func stop(_ queueID: UUID) {
        guard let run = runs.removeValue(forKey: queueID) else { return }
        for id in run.active { stopDownload(id) }
    }

    public func downloadFinished(_ itemID: UUID, outcome: Outcome) {
        guard let queueID = runs.first(where: { $0.value.active.contains(itemID) })?.key,
              let queue = queue(queueID)
        else { return }
        runs[queueID]?.active.remove(itemID)
        switch outcome {
        case .completed:
            runs[queueID]?.done.insert(itemID)
            runs[queueID]?.failures[itemID] = nil
            if queue.kind == .download {
                updateQueue(queueID) { $0.itemIDs.removeAll { $0 == itemID } }
            }
        case .stopped:
            runs[queueID]?.done.insert(itemID)
        case .failed:
            let failures = (runs[queueID]?.failures[itemID] ?? 0) + 1
            runs[queueID]?.failures[itemID] = failures
            if let limit = queue.maxRetries, failures > limit {
                runs[queueID]?.done.insert(itemID)
            } else {
                updateQueue(queueID) { queue in
                    queue.itemIDs.removeAll { $0 == itemID }
                    queue.itemIDs.append(itemID)
                }
                if candidates(queueID).allSatisfy({ $0 == itemID }) {
                    runs[queueID]?.retryAt[itemID] = clock.now.addingTimeInterval(Self.retryInterval)
                }
            }
        }
        fill(queueID)
        checkFinished(queueID)
    }

    /// Handles due retries and scheduled starts and stops.
    public func tick() {
        let now = clock.now
        for queueID in Array(runs.keys) where runs[queueID]?.retryAt.values.contains(where: { $0 <= now }) == true {
            fill(queueID)
        }
        let since = lastTick ?? now
        lastTick = now
        guard since < now else { return }
        for queue in queues {
            if isRunning(queue.id), let stopTime = QueueScheduler.nextStop(after: since, schedule: queue.schedule, calendar: calendar), stopTime <= now {
                stop(queue.id)
            } else if !isRunning(queue.id), let startTime = QueueScheduler.nextStart(after: since, schedule: queue.schedule, calendar: calendar), startTime <= now {
                start(queue.id)
            }
        }
    }

    /// Items still waiting in this run (not running, not done), in queue order.
    private func candidates(_ queueID: UUID) -> [UUID] {
        guard let run = runs[queueID], let queue = queue(queueID) else { return [] }
        return queue.itemIDs.filter { !run.active.contains($0) && !run.checking.contains($0) && !run.done.contains($0) }
    }

    /// Starts files until the queue's "files at the same time" limit is reached.
    private func fill(_ queueID: UUID) {
        while let run = runs[queueID], let queue = queue(queueID),
              run.active.count + run.checking.count < max(1, queue.concurrentDownloads) {
            let now = clock.now
            guard let next = candidates(queueID).first(where: { (runs[queueID]?.retryAt[$0] ?? now) <= now }) else { return }
            runs[queueID]?.retryAt[next] = nil
            runs[queueID]?.hadWork = true
            if itemStatus(next) == .completed {
                if queue.kind == .synchronization {
                    runs[queueID]?.checking.insert(next)
                    checkRemoteChanged(next) { [weak self] changed in
                        self?.remoteChecked(next, in: queueID, changed: changed)
                    }
                } else {
                    runs[queueID]?.done.insert(next)
                    updateQueue(queueID) { $0.itemIDs.removeAll { $0 == next } }
                }
            } else {
                runs[queueID]?.active.insert(next)
                startDownload(next)
            }
        }
    }

    private func remoteChecked(_ itemID: UUID, in queueID: UUID, changed: Bool) {
        guard runs[queueID]?.checking.remove(itemID) != nil else { return }
        if changed {
            runs[queueID]?.active.insert(itemID)
            startDownload(itemID)
        } else {
            runs[queueID]?.done.insert(itemID)
            fill(queueID)
            checkFinished(queueID)
        }
    }

    /// Ends the run when nothing is left; the "when done" action runs only if the run had work.
    private func checkFinished(_ queueID: UUID) {
        guard let run = runs[queueID], let queue = queue(queueID),
              run.active.isEmpty, run.checking.isEmpty, candidates(queueID).isEmpty
        else { return }
        runs[queueID] = nil
        if run.hadWork, queue.postAction != .none {
            performPostAction(queue)
        }
    }
}
