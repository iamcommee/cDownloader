import Foundation
import Testing
@testable import cDownloaderCore

@Suite struct ThrottleTests {
    @Test func t5_01_burstThenWaitThenRefill() {
        let clock = TestClock()
        let bucket = TokenBucket(bytesPerSecond: 1000, clock: clock)
        #expect(bucket.consume(1000) == 0)
        #expect(abs(bucket.consume(500) - 0.5) < 0.0001)
        clock.advance(1.5)
        #expect(bucket.consume(1000) == 0)
    }

    @Test func t5_01_unlimitedNeverWaits() {
        let clock = TestClock()
        let bucket = TokenBucket(bytesPerSecond: 0, clock: clock)
        for _ in 0..<10 { #expect(bucket.consume(10_000_000) == 0) }
    }

    @Test func t5_01_rateChangeAppliesToRefill() {
        let clock = TestClock()
        let bucket = TokenBucket(bytesPerSecond: 1000, clock: clock)
        #expect(bucket.consume(1000) == 0)
        bucket.bytesPerSecond = 500
        #expect(abs(bucket.consume(500) - 1.0) < 0.0001)
        clock.advance(1.0)
        #expect(abs(bucket.consume(250) - 0.5) < 0.0001)
    }

    @Test func t5_02_stricterLimitWinsAndGlobalIsShared() {
        let clock = TestClock()
        let limiter = SpeedLimiter(clock: clock)
        let a = UUID(), b = UUID()
        limiter.globalLimit = 1000
        limiter.setLimit(200, for: a)
        #expect(limiter.limit(for: a) == 200)

        // a: per-download 200 B/s is stricter than the global 1000 B/s.
        _ = limiter.consume(200, for: a)
        #expect(abs(limiter.consume(200, for: a) - 1.0) < 0.0001)

        // Two downloads sharing the global limit over 10 simulated seconds stay at or under it (plus one burst).
        let shared = SpeedLimiter(clock: clock)
        shared.globalLimit = 1000
        var total: Int64 = 0
        let start = clock.now
        while clock.now.timeIntervalSince(start) < 10 {
            let waitA = shared.consume(100, for: a)
            let waitB = shared.consume(100, for: b)
            total += 200
            clock.advance(max(waitA, waitB, 0.01))
        }
        #expect(total <= 1000 * 10 + 1000 + 200)
        #expect(total >= 1000 * 9)
    }

    @Test func t5_02_globalOffMeansOnlyPerDownloadLimits() {
        let clock = TestClock()
        let limiter = SpeedLimiter(clock: clock)
        let id = UUID()
        limiter.globalLimit = 0
        #expect(limiter.consume(1_000_000, for: id) == 0)
        limiter.setLimit(nil, for: id)
        #expect(limiter.limit(for: id) == nil)
    }

    @Test func t5_03_quotaBlocksUntilWindowRolls() throws {
        let clock = TestClock()
        let mb: Int64 = 1_048_576
        let quota = DownloadQuota(limitBytes: 100 * mb, period: 2 * 3600, clock: clock)
        let start = clock.now
        quota.record(40 * mb)
        #expect(quota.nextAllowedAt == nil)
        #expect(quota.usedInWindow == 40 * mb)
        quota.record(60 * mb)
        #expect(quota.nextAllowedAt == start.addingTimeInterval(2 * 3600))
        clock.advance(2 * 3600 - 1)
        #expect(quota.nextAllowedAt != nil)
        clock.advance(1)
        #expect(quota.nextAllowedAt == nil)
        #expect(quota.usedInWindow == 0)
        quota.record(1)
        #expect(quota.usedInWindow == 1)
    }

    @Test func t5_03_disabledQuotaNeverBlocks() {
        let clock = TestClock()
        let quota = DownloadQuota(limitBytes: 10, period: 3600, enabled: false, clock: clock)
        quota.record(1000)
        #expect(quota.nextAllowedAt == nil)
    }
}
