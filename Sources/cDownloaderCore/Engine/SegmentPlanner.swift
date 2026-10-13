import Foundation

/// Decides which byte ranges each connection downloads, using dynamic in-half segmentation:
/// a free connection splits the segment with the most bytes left in two and takes the second half;
/// a connection that reaches its end takes over the next segment if nobody has downloaded from it yet.
public struct SegmentPlanner: Sendable, Equatable {
    public struct Segment: Sendable, Equatable, Identifiable {
        public let id: Int
        public var start: Int64
        public var end: Int64
        public var downloaded: Int64
        /// A connection is working on it.
        public var isActive: Bool

        public var position: Int64 { start + downloaded }
        public var remaining: Int64 { max(0, end - position) }
        public var isFinished: Bool { position >= end }
    }

    public enum EndOutcome: Sendable, Equatable {
        /// The connection keeps reading: it took over the next segment.
        /// `cancelled` is the id of a segment whose connection had not received data yet and must be stopped.
        case continued(cancelled: Int?)
        /// The connection is free.
        case finished
    }

    public private(set) var segments: [Segment] = []
    /// nil while the server has not reported a length.
    public private(set) var totalSize: Int64?
    public let minSegmentSize: Int64
    private var nextID = 0

    public init(totalSize: Int64?, minSegmentSize: Int64) {
        self.totalSize = totalSize
        self.minSegmentSize = max(1, minSegmentSize)
        if let totalSize {
            if totalSize > 0 { segments = [makeSegment(start: 0, end: totalSize)] }
        } else {
            segments = [makeSegment(start: 0, end: Int64.max)]
        }
    }

    /// Restores saved positions; invalid records fall back to a fresh plan.
    public init(restoring records: [SegmentRecord], totalSize: Int64, minSegmentSize: Int64) {
        self.init(totalSize: totalSize, minSegmentSize: minSegmentSize)
        guard Self.isValid(records, totalSize: totalSize) else { return }
        nextID = 0
        segments = records.map { makeSegment(start: $0.start, end: $0.end, downloaded: $0.downloaded) }
    }

    private static func isValid(_ records: [SegmentRecord], totalSize: Int64) -> Bool {
        guard !records.isEmpty else { return false }
        var expected: Int64 = 0
        for record in records {
            guard record.start == expected, record.end > record.start,
                  record.downloaded >= 0, record.downloaded <= record.end - record.start
            else { return false }
            expected = record.end
        }
        return expected == totalSize
    }

    private mutating func makeSegment(start: Int64, end: Int64, downloaded: Int64 = 0) -> Segment {
        defer { nextID += 1 }
        return Segment(id: nextID, start: start, end: end, downloaded: downloaded, isActive: false)
    }

    private func index(of id: Int) -> Int? { segments.firstIndex { $0.id == id } }

    public var records: [SegmentRecord] {
        segments.map { SegmentRecord(start: $0.start, end: $0.end, downloaded: $0.downloaded) }
    }

    public var downloadedBytes: Int64 { segments.reduce(0) { $0 + $1.downloaded } }

    public var isComplete: Bool {
        guard totalSize != nil else { return false }
        return segments.allSatisfy(\.isFinished)
    }

    public var activeCount: Int { segments.filter(\.isActive).count }

    public func segment(_ id: Int) -> Segment? { segments.first { $0.id == id } }

    /// Work for a free connection, or nil when nothing is worth splitting.
    /// Unstarted or abandoned segments are handed out first; otherwise the segment with
    /// the most bytes left is split in half and the new connection starts at the midpoint.
    public mutating func assign() -> Segment? {
        if let idle = segments.firstIndex(where: { !$0.isActive && !$0.isFinished }) {
            segments[idle].isActive = true
            return segments[idle]
        }
        guard totalSize != nil else { return nil }
        var best: Int?
        for (index, segment) in segments.enumerated() where segment.isActive {
            if best == nil || segment.remaining > segments[best!].remaining { best = index }
        }
        guard let best, segments[best].remaining >= 2 * minSegmentSize else { return nil }
        let middle = segments[best].position + segments[best].remaining / 2
        var newSegment = makeSegment(start: middle, end: segments[best].end)
        newSegment.isActive = true
        segments[best].end = middle
        segments.insert(newSegment, at: best + 1)
        return newSegment
    }

    /// Records bytes received for a segment; returns how many fit before its end.
    @discardableResult
    public mutating func record(bytes: Int64, in id: Int) -> Int64 {
        guard let index = index(of: id), bytes > 0 else { return 0 }
        let accepted = min(bytes, segments[index].remaining)
        segments[index].downloaded += accepted
        return accepted
    }

    /// Call when a connection reached the end of its segment.
    public mutating func reachedEnd(_ id: Int) -> EndOutcome {
        guard let index = index(of: id) else { return .finished }
        let next = index + 1
        if next < segments.count, segments[next].downloaded == 0 {
            let absorbed = segments.remove(at: next)
            segments[index].end = absorbed.end
            segments[index].isActive = true
            return .continued(cancelled: absorbed.isActive ? absorbed.id : nil)
        }
        segments[index].isActive = false
        return .finished
    }

    /// The connection on this segment stopped (pause, error, cancel).
    public mutating func release(_ id: Int) {
        guard let index = index(of: id) else { return }
        segments[index].isActive = false
    }

    /// For unknown-length downloads: the stream ended, so the file length is now known.
    public mutating func finishUnknownLength() {
        guard totalSize == nil else { return }
        let length = downloadedBytes
        totalSize = length
        segments = length > 0 ? [Segment(id: nextID, start: 0, end: length, downloaded: length, isActive: false)] : []
        nextID += 1
    }

    public func progress() -> SegmentProgress {
        guard let totalSize, totalSize > 0 else {
            return SegmentProgress(bars: [], downloadedBytes: downloadedBytes, totalBytes: totalSize ?? 0)
        }
        let total = Double(totalSize)
        let bars = segments.map { segment in
            SegmentProgress.Bar(
                startFraction: Double(segment.start) / total,
                downloadedEndFraction: Double(segment.position) / total,
                endFraction: Double(segment.end) / total,
                downloadedBytes: segment.downloaded,
                remainingBytes: segment.remaining,
                isActive: segment.isActive
            )
        }
        return SegmentProgress(bars: bars, downloadedBytes: downloadedBytes, totalBytes: totalSize)
    }
}

/// What the progress window draws: one bar per segment, as fractions of the file.
public struct SegmentProgress: Sendable, Equatable {
    public struct Bar: Sendable, Equatable {
        public var startFraction: Double
        public var downloadedEndFraction: Double
        public var endFraction: Double
        public var downloadedBytes: Int64
        public var remainingBytes: Int64
        public var isActive: Bool
    }

    public var bars: [Bar]
    public var downloadedBytes: Int64
    public var totalBytes: Int64
}

extension SegmentPlanner {
    /// Test hook: marks a restored segment as having a connection.
    mutating func markActiveForTesting(_ id: Int) {
        if let index = segments.firstIndex(where: { $0.id == id }) { segments[index].isActive = true }
    }
}
