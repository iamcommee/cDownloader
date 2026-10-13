import Foundation

/// Works out when a queue's schedule starts and stops it.
public enum QueueScheduler {
    /// The first scheduled start strictly after `date`, or nil when the schedule never starts again.
    public static func nextStart(after date: Date, schedule: QueueSchedule, calendar: Calendar) -> Date? {
        guard schedule.startEnabled else { return nil }
        let today = calendar.startOfDay(for: date)
        switch schedule.repeatRule {
        case .once(let day):
            return startTimes(on: calendar.startOfDay(for: day), schedule: schedule, calendar: calendar).first { $0 > date }
        case .daily:
            for offset in 0...2 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
                if let next = startTimes(on: day, schedule: schedule, calendar: calendar).first(where: { $0 > date }) { return next }
            }
            return nil
        case .weekdays(let weekdays):
            guard !weekdays.isEmpty else { return nil }
            for offset in 0...8 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                      weekdays.contains(calendar.component(.weekday, from: day))
                else { continue }
                if let next = startTimes(on: day, schedule: schedule, calendar: calendar).first(where: { $0 > date }) { return next }
            }
            return nil
        }
    }

    /// The first scheduled stop strictly after `date` (the stop time repeats daily).
    public static func nextStop(after date: Date, schedule: QueueSchedule, calendar: Calendar) -> Date? {
        guard schedule.stopEnabled else { return nil }
        let today = calendar.startOfDay(for: date)
        for offset in 0...2 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let stop = time(schedule.stopTime, on: day, calendar: calendar)
            else { continue }
            if stop > date { return stop }
        }
        return nil
    }

    /// All starts on one day: the start time, plus repeats every N minutes (synchronization)
    /// until the stop time, or until midnight when there is no later stop time.
    static func startTimes(on day: Date, schedule: QueueSchedule, calendar: Calendar) -> [Date] {
        guard let first = time(schedule.startTime, on: day, calendar: calendar) else { return [] }
        guard let minutes = schedule.repeatEveryMinutes, minutes > 0 else { return [first] }
        var windowEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) ?? first
        if schedule.stopEnabled, schedule.stopTime > schedule.startTime, let stop = time(schedule.stopTime, on: day, calendar: calendar) {
            windowEnd = stop
        }
        var times: [Date] = []
        var next = first
        while next < windowEnd {
            times.append(next)
            next = next.addingTimeInterval(TimeInterval(minutes * 60))
        }
        return times
    }

    /// The given time of day; a time skipped by a daylight-saving change moves to the next valid time.
    static func time(_ time: TimeOfDay, on day: Date, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day, matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }
}
