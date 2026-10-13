import Foundation
import Testing
@testable import cDownloaderCore

@Suite struct PlannerTests {
    /// Drives a planner into a given layout: each tuple is (end, downloaded, active) in order, starting at 0.
    func planner(total: Int64, min: Int64, layout: [(end: Int64, downloaded: Int64, active: Bool)]) throws -> SegmentPlanner {
        var start: Int64 = 0
        let records = layout.map { entry -> SegmentRecord in
            defer { start = entry.end }
            return SegmentRecord(start: start, end: entry.end, downloaded: entry.downloaded)
        }
        var planner = SegmentPlanner(restoring: records, totalSize: total, minSegmentSize: min)
        try #require(planner.segments.count == layout.count)
        for (index, entry) in layout.enumerated() where entry.active {
            let id = planner.segments[index].id
            planner.markActiveForTesting(id)
        }
        return planner
    }

    func assertCoverage(_ planner: SegmentPlanner, total: Int64, sourceLocation: SourceLocation = #_sourceLocation) {
        var expectedStart: Int64 = 0
        for segment in planner.segments {
            #expect(segment.start == expectedStart, "gap or overlap at \(segment.start)", sourceLocation: sourceLocation)
            #expect(segment.end > segment.start || total == 0, sourceLocation: sourceLocation)
            #expect(segment.downloaded <= segment.end - segment.start, sourceLocation: sourceLocation)
            expectedStart = segment.end
        }
        #expect(expectedStart == total, sourceLocation: sourceLocation)
    }

    @Test func t4_01_firstConnectionGetsWholeFile() throws {
        var planner = SegmentPlanner(totalSize: 1000, minSegmentSize: 100)
        let firstAssigned = planner.assign(); let first = try #require(firstAssigned)
        #expect(first.start == 0 && first.end == 1000 && first.isActive)
        #expect(planner.segments.count == 1)
    }

    @Test func t4_01_unknownSizeIsOneOpenSegmentThatNeverSplits() throws {
        var planner = SegmentPlanner(totalSize: nil, minSegmentSize: 100)
        let firstAssigned = planner.assign(); let first = try #require(firstAssigned)
        #expect(first.start == 0 && first.end == Int64.max)
        #expect(planner.record(bytes: 5000, in: first.id) == 5000)
        #expect(planner.assign() == nil)
        planner.finishUnknownLength()
        #expect(planner.totalSize == 5000)
        #expect(planner.isComplete)
    }

    @Test func t4_01_zeroSizeIsCompleteAtOnce() {
        var planner = SegmentPlanner(totalSize: 0, minSegmentSize: 100)
        #expect(planner.isComplete)
        #expect(planner.assign() == nil)
    }

    struct SplitRow: Sendable, CustomTestStringConvertible {
        var label: String
        var total: Int64
        var layout: [SegmentLayout]
        var expectedNew: ClosedRange<Int64>?   // start...end of the new segment
        var testDescription: String { label }
    }

    struct SegmentLayout: Sendable {
        var end: Int64
        var downloaded: Int64
        var active: Bool
    }

    @Test(arguments: [
        SplitRow(label: "first split", total: 1000, layout: [.init(end: 1000, downloaded: 0, active: true)], expectedNew: 500...1000),
        SplitRow(label: "remaining not size", total: 1200, layout: [.init(end: 1000, downloaded: 900, active: true), .init(end: 1200, downloaded: 0, active: true)], expectedNew: 1100...1200),
        SplitRow(label: "tie picks lowest", total: 800, layout: [.init(end: 400, downloaded: 0, active: true), .init(end: 800, downloaded: 0, active: true)], expectedNew: 200...400),
        SplitRow(label: "exact limit", total: 200, layout: [.init(end: 200, downloaded: 0, active: true)], expectedNew: 100...200),
        SplitRow(label: "below limit", total: 199, layout: [.init(end: 199, downloaded: 0, active: true)], expectedNew: nil),
        SplitRow(label: "odd", total: 1201, layout: [.init(end: 1000, downloaded: 1000, active: false), .init(end: 1201, downloaded: 0, active: true)], expectedNew: 1100...1201),
    ])
    func t4_02_splitsLargestRemainingInHalf(row: SplitRow) throws {
        var planner = try planner(total: row.total, min: 100, layout: row.layout.map { ($0.end, $0.downloaded, $0.active) })
        let new = planner.assign()
        if let expected = row.expectedNew {
            #expect(new?.start == expected.lowerBound)
            #expect(new?.end == expected.upperBound)
            #expect(new?.isActive == true)
            #expect(planner.segments.contains { $0.end == expected.lowerBound })
        } else {
            #expect(new == nil)
        }
        assertCoverage(planner, total: row.total)
    }

    @Test func t4_02_idleUnfinishedSegmentIsReusedBeforeSplitting() throws {
        var planner = try planner(total: 1000, min: 100, layout: [(500, 100, false), (1000, 200, true)])
        let nextAssigned = planner.assign(); let next = try #require(nextAssigned)
        #expect(next.start == 0 && next.downloaded == 100)
        #expect(planner.segments.count == 2)
    }

    @Test func t4_02_randomOperationsKeepContiguousCoverage() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let total = Int64.random(in: 1...5_000_000, using: &generator)
            var planner = SegmentPlanner(totalSize: total, minSegmentSize: 4096)
            for _ in 0..<300 {
                switch Int.random(in: 0..<4, using: &generator) {
                case 0:
                    _ = planner.assign()
                case 1, 2:
                    if let segment = planner.segments.filter(\.isActive).randomElement(using: &generator) {
                        planner.record(bytes: Int64.random(in: 1...200_000, using: &generator), in: segment.id)
                        if planner.segment(segment.id)?.isFinished == true { _ = planner.reachedEnd(segment.id) }
                    }
                default:
                    if let segment = planner.segments.filter(\.isActive).randomElement(using: &generator) {
                        planner.release(segment.id)
                    }
                }
                assertCoverage(planner, total: total)
            }
        }
    }

    @Test func t4_03_finishedConnectionAbsorbsIdleNextSegment() throws {
        var planner = try planner(total: 1000, min: 100, layout: [(500, 499, true), (1000, 0, false)])
        let a = planner.segments[0]
        #expect(planner.record(bytes: 1, in: a.id) == 1)
        #expect(planner.reachedEnd(a.id) == .continued(cancelled: nil))
        #expect(planner.segments.count == 1)
        #expect(planner.segments[0].end == 1000 && planner.segments[0].isActive)
    }

    @Test func t4_03_absorbsActiveNextSegmentThatHasNotReceivedData() throws {
        var planner = try planner(total: 1000, min: 100, layout: [(500, 500, true), (1000, 0, true)])
        let b = planner.segments[1]
        #expect(planner.reachedEnd(planner.segments[0].id) == .continued(cancelled: b.id))
        #expect(planner.segments.count == 1 && planner.segments[0].end == 1000)
    }

    @Test func t4_03_startedNextSegmentIsNotAbsorbed() throws {
        var planner = try planner(total: 1000, min: 100, layout: [(500, 500, true), (1000, 10, true)])
        let a = planner.segments[0]
        #expect(planner.reachedEnd(a.id) == .finished)
        #expect(planner.segments.count == 2)
        #expect(planner.segment(a.id)?.isActive == false)
    }

    @Test func t4_04_completeWhenAllFullAndWritesClampedToEnd() throws {
        var planner = SegmentPlanner(totalSize: 1000, minSegmentSize: 100)
        let aAssigned = planner.assign(); let a = try #require(aAssigned)
        let bAssigned = planner.assign(); let b = try #require(bAssigned)
        #expect(planner.record(bytes: 100, in: b.id) == 100)
        #expect(planner.record(bytes: 800, in: a.id) == 500)
        #expect(planner.reachedEnd(a.id) == .finished)
        #expect(!planner.isComplete)
        #expect(planner.record(bytes: 500, in: b.id) == 400)
        _ = planner.reachedEnd(b.id)
        #expect(planner.isComplete)
        #expect(planner.downloadedBytes == 1000)
        #expect(planner.records == [SegmentRecord(start: 0, end: 500, downloaded: 500), SegmentRecord(start: 500, end: 1000, downloaded: 500)])
    }

    @Test func t4_04_restoringInvalidRecordsStartsFresh() {
        let broken = [SegmentRecord(start: 0, end: 400, downloaded: 10), SegmentRecord(start: 500, end: 1000, downloaded: 0)]
        let planner = SegmentPlanner(restoring: broken, totalSize: 1000, minSegmentSize: 100)
        #expect(planner.records == [SegmentRecord(start: 0, end: 1000, downloaded: 0)])
        let valid = [SegmentRecord(start: 0, end: 400, downloaded: 10), SegmentRecord(start: 400, end: 1000, downloaded: 7)]
        #expect(SegmentPlanner(restoring: valid, totalSize: 1000, minSegmentSize: 100).downloadedBytes == 17)
    }

    @Test func t4_05_progressModelMatchesPlannerState() throws {
        var planner = SegmentPlanner(totalSize: 1000, minSegmentSize: 100)
        let aAssigned = planner.assign(); let a = try #require(aAssigned)
        let bAssigned = planner.assign(); let b = try #require(bAssigned)
        planner.record(bytes: 250, in: a.id)
        planner.record(bytes: 100, in: b.id)
        let model = planner.progress()
        #expect(model.totalBytes == 1000)
        #expect(model.downloadedBytes == 350)
        #expect(model.bars.map(\.startFraction) == [0, 0.5])
        #expect(model.bars.map(\.downloadedEndFraction) == [0.25, 0.6])
        #expect(model.bars.map(\.endFraction) == [0.5, 1])
        #expect(model.bars.map(\.remainingBytes) == [250, 400])
        #expect(model.bars.map(\.downloadedBytes).reduce(0, +) == 350)

        let empty = SegmentPlanner(totalSize: 0, minSegmentSize: 100).progress()
        #expect(empty.bars.isEmpty && empty.totalBytes == 0)
    }
}
