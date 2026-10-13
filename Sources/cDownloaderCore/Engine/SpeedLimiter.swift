import Foundation

/// Classic token bucket holding up to one second of traffic.
/// Callers report bytes after reading them and pause for the returned time.
public final class TokenBucket: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: TimeSource
    private var rate: Int64
    private var tokens: Double
    private var lastRefill: Date

    /// `bytesPerSecond` of 0 or less means unlimited.
    public init(bytesPerSecond: Int64, clock: TimeSource = SystemTimeSource()) {
        self.clock = clock
        self.rate = bytesPerSecond
        self.tokens = Double(max(0, bytesPerSecond))
        self.lastRefill = clock.now
    }

    public var bytesPerSecond: Int64 {
        get { lock.withLock { rate } }
        set { lock.withLock { rate = newValue } }
    }

    /// Takes `bytes` from the bucket and returns how long to wait before reading more.
    public func consume(_ bytes: Int64) -> TimeInterval {
        lock.withLock {
            guard rate > 0 else { return 0 }
            let now = clock.now
            let capacity = Double(rate)
            tokens = min(capacity, tokens + now.timeIntervalSince(lastRefill) * Double(rate))
            lastRefill = now
            tokens -= Double(bytes)
            return tokens >= 0 ? 0 : -tokens / Double(rate)
        }
    }
}

/// A global limit shared by all downloads plus optional per-download limits.
public final class SpeedLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: TimeSource
    private var global: TokenBucket?
    private var perDownload: [UUID: TokenBucket] = [:]

    public init(clock: TimeSource = SystemTimeSource()) {
        self.clock = clock
    }

    /// nil or 0 turns the global limit off.
    public var globalLimit: Int64? {
        get { lock.withLock { global?.bytesPerSecond } }
        set {
            lock.withLock {
                guard let newValue, newValue > 0 else { return global = nil }
                if let global { global.bytesPerSecond = newValue } else { global = TokenBucket(bytesPerSecond: newValue, clock: clock) }
            }
        }
    }

    public func setLimit(_ bytesPerSecond: Int64?, for id: UUID) {
        lock.withLock {
            guard let bytesPerSecond, bytesPerSecond > 0 else { return perDownload[id] = nil }
            if let bucket = perDownload[id] {
                bucket.bytesPerSecond = bytesPerSecond
            } else {
                perDownload[id] = TokenBucket(bytesPerSecond: bytesPerSecond, clock: clock)
            }
        }
    }

    public func limit(for id: UUID) -> Int64? { lock.withLock { perDownload[id]?.bytesPerSecond } }

    public func remove(_ id: UUID) { lock.withLock { perDownload[id] = nil } }

    /// Reports bytes read by a download and returns the pause both limits require.
    public func consume(_ bytes: Int64, for id: UUID) -> TimeInterval {
        let (global, own) = lock.withLock { (self.global, perDownload[id]) }
        return max(global?.consume(bytes) ?? 0, own?.consume(bytes) ?? 0)
    }
}

/// "At most X bytes every Y hours": once the window's budget is spent, downloads wait for the next window.
public final class DownloadQuota: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: TimeSource
    private var windowStart: Date?
    private var used: Int64 = 0
    public private(set) var limitBytes: Int64
    public private(set) var period: TimeInterval
    public private(set) var enabled: Bool

    public init(limitBytes: Int64, period: TimeInterval, enabled: Bool = true, clock: TimeSource = SystemTimeSource()) {
        self.limitBytes = limitBytes
        self.period = period
        self.enabled = enabled
        self.clock = clock
    }

    public func configure(limitBytes: Int64, period: TimeInterval, enabled: Bool) {
        lock.withLock {
            self.limitBytes = limitBytes
            self.period = period
            self.enabled = enabled
        }
    }

    public func record(_ bytes: Int64) {
        lock.withLock {
            guard enabled else { return }
            rollWindow()
            if windowStart == nil { windowStart = clock.now }
            used += bytes
        }
    }

    public var usedInWindow: Int64 { lock.withLock { rollWindow(); return used } }

    /// nil when downloading may continue now; otherwise when the next window opens.
    public var nextAllowedAt: Date? {
        lock.withLock {
            guard enabled else { return nil }
            rollWindow()
            guard let windowStart, used >= limitBytes else { return nil }
            return windowStart.addingTimeInterval(period)
        }
    }

    /// Starts a fresh window once the current one has ended.
    private func rollWindow() {
        if let start = windowStart, clock.now >= start.addingTimeInterval(period) {
            windowStart = nil
            used = 0
        }
    }
}
