import Foundation

struct Settings: Codable, Equatable {
    var dayK = 6500.0
    var nightK = 3400.0
    var lateK = 2300.0
    var bedtimeEnabled = true
    var wakeMinutes = 7 * 60
    var sleepMinutes = 510
    /// Minutes; negative starts the evening fade earlier, positive ends the morning fade later.
    var eveningOffset = 0.0
    var morningOffset = 0.0
    var fastTransitions = false
    var boost = false

    var bedtimeMinutes: Int { ((wakeMinutes - sleepMinutes) % 1440 + 1440) % 1440 }
}

struct Inputs: Equatable {
    var lat: Double
    var lon: Double
    var cloudCover: Double?
    var darkness = 0.0
}

enum Phase: String {
    case day = "Day", sunset = "Sunset", bedtime = "Bedtime", boost = "Morning boost"
}

struct ColorState: Equatable {
    var kelvin: Double
    var dim: Double
    var night: Double
    var late: Double
    var boost: Double

    var phase: Phase {
        if late > 0.5 { return .bedtime }
        if boost > 0.5 { return .boost }
        return night > 0.5 ? .sunset : .day
    }

    /// 0 in full day, 1 in full night or bedtime; drives backlight and dark mode.
    var darkness: Double { max(night, late) }

    func differs(from other: ColorState) -> Bool {
        abs(kelvin - other.kelvin) >= 1 || abs(dim - other.dim) >= 0.002 || abs(darkness - other.darkness) >= 0.002
    }
}

enum Blend {
    static let dayElevation = 3.0
    static let cloudyDayElevation = 10.0
    static let nightElevation = -6.0
    static let cloudyThreshold = 80.0
    static let bedtimeFade = 30.0 * 60
    static let wakeFade = 20.0 * 60
    static let boostLength = 30.0 * 60
    static let boostFade = 10.0 * 60
    static let boostK = 7000.0
    static let ambientWeight = 0.6
    static let ambientDim = 0.2

    static func state(at t: Date, settings s: Settings, inputs: Inputs, calendar: Calendar) -> ColorState {
        let night = max(solarNight(at: t, settings: s, inputs: inputs), inputs.darkness * ambientWeight)
        let late = s.bedtimeEnabled ? lateFactor(at: t, settings: s, calendar: calendar) : 0
        let boost = s.boost ? boostFactor(at: t, settings: s, inputs: inputs, calendar: calendar) : 0

        var k = s.dayK + (s.nightK - s.dayK) * night
        if late > 0, s.lateK < k { k += (s.lateK - k) * late }
        if boost > 0 { k += (boostK - k) * boost * (1 - night) }
        return ColorState(kelvin: k, dim: 1 - ambientDim * inputs.darkness, night: night, late: late, boost: boost)
    }

    static func solarNight(at t: Date, settings s: Settings, inputs: Inputs) -> Double {
        let rising = Solar.isRising(at: t, lat: inputs.lat, lon: inputs.lon)
        let offset = (rising ? s.morningOffset : s.eveningOffset) * 60
        let elevation = Solar.elevation(at: t.addingTimeInterval(-offset), lat: inputs.lat, lon: inputs.lon)
        let day = (inputs.cloudCover ?? 0) >= cloudyThreshold ? cloudyDayElevation : dayElevation
        let v = min(1, max(0, (day - elevation) / (day - nightElevation)))
        return s.fastTransitions ? (v >= 0.5 ? 1 : 0) : v
    }

    static func lateFactor(at t: Date, settings s: Settings, calendar: Calendar) -> Double {
        // Wall clock minutes, so DST days do not shift bedtime by an hour.
        let local = t.timeIntervalSince1970 + Double(calendar.timeZone.secondsFromGMT(for: t))
        let minutes = local.mod(86400) / 60
        let sinceBed = (minutes - Double(s.bedtimeMinutes)).mod(1440)
        if sinceBed < Double(s.sleepMinutes) {
            return s.fastTransitions ? 1 : min(1, sinceBed * 60 / bedtimeFade)
        }
        let sinceWake = (minutes - Double(s.wakeMinutes)).mod(1440)
        if !s.fastTransitions, sinceWake * 60 < wakeFade { return 1 - sinceWake * 60 / wakeFade }
        return 0
    }

    static func boostFactor(at t: Date, settings s: Settings, inputs: Inputs, calendar: Calendar) -> Double {
        let start = boostStart(on: t, settings: s, inputs: inputs, calendar: calendar)
        let dt = t.timeIntervalSince(start)
        if dt < 0 || dt >= boostLength + boostFade { return 0 }
        return dt < boostLength ? 1 : 1 - (dt - boostLength) / boostFade
    }

    private static var dawnCache: [String: Date] = [:]

    /// Later of civil dawn and wake time on the local day of `t`.
    static func boostStart(on t: Date, settings s: Settings, inputs: Inputs, calendar: Calendar) -> Date {
        let midnight = calendar.startOfDay(for: t)
        let wake = calendar.date(bySettingHour: s.wakeMinutes / 60, minute: s.wakeMinutes % 60, second: 0, of: midnight) ?? midnight
        let key = "\(midnight.timeIntervalSince1970),\(inputs.lat),\(inputs.lon)"
        let dawn = dawnCache[key] ?? {
            let d = Solar.nextCrossing(after: midnight, lat: inputs.lat, lon: inputs.lon,
                                       threshold: nightElevation, rising: true, window: 86400) ?? wake
            if dawnCache.count > 64 { dawnCache.removeAll() }
            dawnCache[key] = d
            return d
        }()
        return max(dawn, wake)
    }
}

enum Schedule {
    /// First minute after `t` where the color differs from now, or nil if nothing changes within 26 h (polar day or night).
    static func nextChange(after t: Date, settings: Settings, inputs: Inputs, calendar: Calendar,
                           step: TimeInterval = 60, horizon: TimeInterval = 26 * 3600) -> Date? {
        let now = Blend.state(at: t, settings: settings, inputs: inputs, calendar: calendar)
        var x = t.addingTimeInterval(step)
        while x.timeIntervalSince(t) <= horizon {
            let changed = autoreleasepool {
                Blend.state(at: x, settings: settings, inputs: inputs, calendar: calendar).differs(from: now)
            }
            if changed { return x }
            x.addTimeInterval(step)
        }
        return nil
    }

    static func inTransition(at t: Date, settings: Settings, inputs: Inputs, calendar: Calendar) -> Bool {
        let a = Blend.state(at: t, settings: settings, inputs: inputs, calendar: calendar)
        let b = Blend.state(at: t.addingTimeInterval(10), settings: settings, inputs: inputs, calendar: calendar)
        return a.differs(from: b)
    }

    /// Where the next change settles: its start time and the state once it stops changing for 10 min.
    static func nextTarget(after t: Date, settings: Settings, inputs: Inputs,
                           calendar: Calendar) -> (start: Date, state: ColorState)? {
        let from = inTransition(at: t, settings: settings, inputs: inputs, calendar: calendar) ? t : nil
        guard let start = from ?? nextChange(after: t, settings: settings, inputs: inputs, calendar: calendar) else { return nil }
        var x = start
        var last = Blend.state(at: x, settings: settings, inputs: inputs, calendar: calendar)
        var stableSince = x
        while x.timeIntervalSince(start) < 4 * 3600 {
            x.addTimeInterval(60)
            let s = Blend.state(at: x, settings: settings, inputs: inputs, calendar: calendar)
            if s.differs(from: last) { stableSince = x; last = s }
            if x.timeIntervalSince(stableSince) >= 600 { break }
        }
        return (start, last)
    }
}

extension Double {
    func mod(_ m: Double) -> Double {
        let r = truncatingRemainder(dividingBy: m)
        return r < 0 ? r + m : r
    }
}
