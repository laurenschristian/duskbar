import XCTest
@testable import DuskCore

private func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

private func calendar(_ tz: String) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: tz)!
    return c
}

private func maxElevation(on day: String, lat: Double, lon: Double) -> (min: Double, max: Double) {
    let start = utc("\(day)T00:00:00Z")
    let values = stride(from: 0.0, to: 86400, by: 120).map { Solar.elevation(at: start.addingTimeInterval($0), lat: lat, lon: lon) }
    return (values.min()!, values.max()!)
}

private let amsterdam = Inputs(lat: 52.37, lon: 4.90)
private let ams = calendar("Europe/Amsterdam")

final class SolarTests: XCTestCase {
    func testNoonElevationMatchesDeclination() {
        XCTAssertEqual(maxElevation(on: "2026-06-21", lat: 52.37, lon: 4.90).max, 90 - 52.37 + 23.44, accuracy: 0.2)
        XCTAssertEqual(maxElevation(on: "2026-12-21", lat: 52.37, lon: 4.90).max, 90 - 52.37 - 23.44, accuracy: 0.2)
        XCTAssertGreaterThan(maxElevation(on: "2026-03-20", lat: -0.18, lon: -78.47).max, 89.4)
        XCTAssertEqual(maxElevation(on: "2026-12-21", lat: -36.85, lon: 174.76).max, 90 - 36.85 + 23.44, accuracy: 0.2)
    }

    func testSunriseSunsetAmsterdam() {
        let rise = Solar.nextCrossing(after: utc("2026-06-21T00:00:00Z"), lat: 52.37, lon: 4.90, threshold: -0.833, rising: true)!
        let set = Solar.nextCrossing(after: rise, lat: 52.37, lon: 4.90, threshold: -0.833, rising: false)!
        XCTAssertEqual(rise.timeIntervalSince(utc("2026-06-21T03:18:00Z")), 0, accuracy: 180)
        XCTAssertEqual(set.timeIntervalSince(utc("2026-06-21T20:06:00Z")), 0, accuracy: 180)
        let winterRise = Solar.nextCrossing(after: utc("2026-12-21T00:00:00Z"), lat: 52.37, lon: 4.90, threshold: -0.833, rising: true)!
        XCTAssertEqual(winterRise.timeIntervalSince(utc("2026-12-21T07:48:00Z")), 0, accuracy: 180)
    }

    func testEquatorDayLength() {
        let rise = Solar.nextCrossing(after: utc("2026-03-20T00:00:00Z"), lat: -0.18, lon: -78.47, threshold: -0.833, rising: true)!
        let set = Solar.nextCrossing(after: rise, lat: -0.18, lon: -78.47, threshold: -0.833, rising: false)!
        XCTAssertEqual(set.timeIntervalSince(rise) / 60, 12 * 60 + 7, accuracy: 3)
    }

    func testPolarDayAndNight() {
        XCTAssertGreaterThan(maxElevation(on: "2026-06-21", lat: 69.65, lon: 18.96).min, 0)
        XCTAssertLessThan(maxElevation(on: "2026-12-21", lat: 69.65, lon: 18.96).max, 0)
        XCTAssertNil(Solar.nextCrossing(after: utc("2026-06-21T00:00:00Z"), lat: 69.65, lon: 18.96,
                                        threshold: 0, rising: false, window: 86400))
    }

    func testDateLine() {
        let e = maxElevation(on: "2026-06-21", lat: -13.83, lon: -171.76)
        XCTAssertEqual(e.max, 90 - 13.83 - 23.44, accuracy: 0.3)
    }
}

final class KelvinTests: XCTestCase {
    func testWhitePoint() {
        let c = Kelvin.rgb(6500)
        XCTAssertEqual(c.r, 1, accuracy: 0.01)
        XCTAssertEqual(c.g, 1, accuracy: 0.01)
        XCTAssertEqual(c.b, 1, accuracy: 0.01)
    }

    func testMatchesReferenceTable() {
        XCTAssertEqual(Kelvin.rgb(1000).g, 0.1817, accuracy: 0.01)
        XCTAssertEqual(Kelvin.rgb(1200).g, 0.3094, accuracy: 0.015)
        XCTAssertEqual(Kelvin.rgb(10000).r, 0.7899, accuracy: 0.01)
        XCTAssertEqual(Kelvin.rgb(10000).g, 0.8649, accuracy: 0.01)
    }

    func testMonotonicBelowWhite() {
        var last = Kelvin.rgb(1000)
        for k in stride(from: 1050.0, through: 6500, by: 50) {
            let c = Kelvin.rgb(k)
            XCTAssertGreaterThanOrEqual(c.g, last.g)
            XCTAssertGreaterThanOrEqual(c.b, last.b)
            XCTAssertEqual(c.r, 1, accuracy: 0.001)
            last = c
        }
    }

    func testClampsOutOfRange() {
        XCTAssertEqual(Kelvin.rgb(500), Kelvin.rgb(1000))
        XCTAssertEqual(Kelvin.rgb(20000), Kelvin.rgb(10000))
    }
}

final class GammaTableTests: XCTestCase {
    func testShapeAndMonotonic() {
        let t = GammaTable(kelvin: 3400)
        XCTAssertEqual(t.r.count, 256)
        XCTAssertEqual(t.r[0], 0)
        for i in 1..<256 { XCTAssertGreaterThanOrEqual(t.g[i], t.g[i - 1]) }
        XCTAssertEqual(Double(t.b[255]), Kelvin.rgb(3400).b, accuracy: 0.0001)
    }

    func testDimScalesLinearly() {
        let full = GammaTable(kelvin: 5000), half = GammaTable(kelvin: 5000, dim: 0.5)
        XCTAssertEqual(half.g[200], full.g[200] * 0.5, accuracy: 0.0001)
    }

    func testDarkroom() {
        let t = GammaTable(kelvin: 3400, darkroom: true)
        XCTAssertEqual(t.r[0], 1)
        XCTAssertEqual(t.r[255], 0)
        XCTAssertTrue(t.g.allSatisfy { $0 == 0 } && t.b.allSatisfy { $0 == 0 })
    }

    func testMatches() {
        XCTAssertTrue(GammaTable(kelvin: 3400).matches(GammaTable(kelvin: 3405)))
        XCTAssertFalse(GammaTable(kelvin: 3400).matches(GammaTable(kelvin: 6500)))
    }
}

final class BlendTests: XCTestCase {
    var s = Settings(dayK: 6500, nightK: 3400, lateK: 2000, bedtimeEnabled: false, wakeMinutes: 480, sleepMinutes: 510)

    func testDayAndNight() {
        XCTAssertEqual(Blend.state(at: utc("2026-06-21T12:00:00Z"), settings: s, inputs: amsterdam, calendar: ams).kelvin, 6500)
        XCTAssertEqual(Blend.state(at: utc("2026-06-21T23:00:00Z"), settings: s, inputs: amsterdam, calendar: ams).kelvin, 3400)
        XCTAssertEqual(Blend.state(at: utc("2026-06-21T23:00:00Z"), settings: s, inputs: amsterdam, calendar: ams).phase, .sunset)
    }

    func testTwilightMidpoint() {
        let mid = Solar.nextCrossing(after: utc("2026-06-21T12:00:00Z"), lat: 52.37, lon: 4.90, threshold: -1.5, rising: false)!
        let st = Blend.state(at: mid, settings: s, inputs: amsterdam, calendar: ams)
        XCTAssertEqual(st.night, 0.5, accuracy: 0.01)
        XCTAssertEqual(st.kelvin, 4950, accuracy: 20)
    }

    func testBedtime() {
        s.bedtimeEnabled = true
        // Bedtime 23:30 local, 30 min fade: 23:45 is halfway, 01:00 is full.
        let half = Blend.state(at: utc("2026-06-21T21:45:00Z"), settings: s, inputs: amsterdam, calendar: ams)
        XCTAssertEqual(half.late, 0.5, accuracy: 0.01)
        XCTAssertEqual(half.kelvin, 2700, accuracy: 1)
        let full = Blend.state(at: utc("2026-06-21T23:00:00Z"), settings: s, inputs: amsterdam, calendar: ams)
        XCTAssertEqual(full.kelvin, 2000)
        XCTAssertEqual(full.phase, .bedtime)
        // 08:10 local: 10 of 20 wake fade minutes gone.
        XCTAssertEqual(Blend.state(at: utc("2026-06-22T06:10:00Z"), settings: s, inputs: amsterdam, calendar: ams).late, 0.5, accuracy: 0.01)
    }

    func testBedtimeAcrossDSTStart() {
        s.bedtimeEnabled = true
        // 2026-03-29 02:00 local jumps to 03:00; 03:30 CEST is 01:30Z.
        XCTAssertEqual(Blend.state(at: utc("2026-03-29T01:30:00Z"), settings: s, inputs: amsterdam, calendar: ams).late, 1)
        XCTAssertNotNil(Schedule.nextChange(after: utc("2026-03-28T20:00:00Z"), settings: s, inputs: amsterdam, calendar: ams))
        // DST end day (25 h): bedtime still starts at 23:30 wall clock (22:30Z in CET).
        XCTAssertEqual(Blend.lateFactor(at: utc("2026-10-25T22:45:00Z"), settings: s, calendar: ams), 0.5, accuracy: 0.01)
        XCTAssertEqual(Blend.lateFactor(at: utc("2026-03-29T21:45:00Z"), settings: s, calendar: ams), 0.5, accuracy: 0.01)
    }

    func testAmbientDarkness() {
        var i = amsterdam
        i.darkness = 1
        let st = Blend.state(at: utc("2026-06-21T12:00:00Z"), settings: s, inputs: i, calendar: ams)
        XCTAssertEqual(st.night, 0.6, accuracy: 0.001)
        XCTAssertEqual(st.dim, 0.8, accuracy: 0.001)
        XCTAssertEqual(st.kelvin, 6500 - 0.6 * 3100, accuracy: 1)
    }

    func testCloudsStartEarlier() {
        let fiveDeg = Solar.nextCrossing(after: utc("2026-06-21T12:00:00Z"), lat: 52.37, lon: 4.90, threshold: 5, rising: false)!
        var cloudy = amsterdam
        cloudy.cloudCover = 90
        XCTAssertEqual(Blend.state(at: fiveDeg, settings: s, inputs: amsterdam, calendar: ams).night, 0)
        XCTAssertGreaterThan(Blend.state(at: fiveDeg, settings: s, inputs: cloudy, calendar: ams).night, 0.2)
    }

    func testMorningBoost() {
        s.boost = true
        // Civil dawn is ~04:30 local in June, so the boost starts at wake time 08:00.
        let start = Blend.boostStart(on: utc("2026-06-21T12:00:00Z"), settings: s, inputs: amsterdam, calendar: ams)
        XCTAssertEqual(start, utc("2026-06-21T06:00:00Z"))
        XCTAssertEqual(Blend.state(at: utc("2026-06-21T06:10:00Z"), settings: s, inputs: amsterdam, calendar: ams).kelvin, 7000)
        XCTAssertEqual(Blend.state(at: utc("2026-06-21T06:35:00Z"), settings: s, inputs: amsterdam, calendar: ams).boost, 0.5, accuracy: 0.01)
        XCTAssertEqual(Blend.state(at: utc("2026-06-21T07:00:00Z"), settings: s, inputs: amsterdam, calendar: ams).kelvin, 6500)
    }

    func testFastTransitionsSnap() {
        s.fastTransitions = true
        let mid = Solar.nextCrossing(after: utc("2026-06-21T12:00:00Z"), lat: 52.37, lon: 4.90, threshold: -2, rising: false)!
        XCTAssertEqual(Blend.state(at: mid, settings: s, inputs: amsterdam, calendar: ams).night, 1)
    }
}

final class ScheduleTests: XCTestCase {
    let s = Settings(dayK: 6500, nightK: 3400, lateK: 2000, bedtimeEnabled: false, wakeMinutes: 480, sleepMinutes: 510)

    func testNextChangeIsEveningThreshold() {
        let noon = utc("2026-06-21T12:00:00Z")
        let expected = Solar.nextCrossing(after: noon, lat: 52.37, lon: 4.90, threshold: Blend.dayElevation, rising: false)!
        let next = Schedule.nextChange(after: noon, settings: s, inputs: amsterdam, calendar: ams)!
        XCTAssertEqual(next.timeIntervalSince(expected), 0, accuracy: 61)
    }

    func testEveningOffsetShiftsStart() {
        var early = s
        early.eveningOffset = -30
        let noon = utc("2026-06-21T12:00:00Z")
        let a = Schedule.nextChange(after: noon, settings: s, inputs: amsterdam, calendar: ams)!
        let b = Schedule.nextChange(after: noon, settings: early, inputs: amsterdam, calendar: ams)!
        XCTAssertEqual(a.timeIntervalSince(b), 1800, accuracy: 61)
    }

    func testPolarDayHasNoChange() {
        let tromso = Inputs(lat: 69.65, lon: 18.96)
        XCTAssertNil(Schedule.nextChange(after: utc("2026-06-21T12:00:00Z"), settings: s, inputs: tromso, calendar: calendar("Europe/Oslo")))
    }

    func testNextTargetSettles() {
        let t = Schedule.nextTarget(after: utc("2026-06-21T12:00:00Z"), settings: s, inputs: amsterdam, calendar: ams)!
        XCTAssertEqual(t.state.kelvin, 3400)
    }

    func testTimeZoneChangeMovesBedtime() {
        var b = s
        b.bedtimeEnabled = true
        let t = utc("2026-06-21T12:00:00Z")
        let inChicago = Blend.lateFactor(at: utc("2026-06-22T05:00:00Z"), settings: b, calendar: calendar("America/Chicago"))
        let inAmsterdam = Blend.lateFactor(at: utc("2026-06-22T05:00:00Z"), settings: b, calendar: ams)
        XCTAssertEqual(inChicago, 1)
        XCTAssertEqual(inAmsterdam, 1)
        XCTAssertEqual(Blend.lateFactor(at: t, settings: b, calendar: ams), 0)
    }
}

final class ParsingTests: XCTestCase {
    func testURLCommands() {
        XCTAssertEqual(Command.parse(URL(string: "duskbar://disable?minutes=60")!), .disable(minutes: 60))
        XCTAssertEqual(Command.parse(URL(string: "duskbar://disable")!), .disable(minutes: nil))
        XCTAssertEqual(Command.parse(URL(string: "duskbar://enable")!), .enable)
        XCTAssertEqual(Command.parse(URL(string: "duskbar://temp?k=90000&minutes=0")!), .temp(kelvin: 6500, minutes: 1))
        XCTAssertEqual(Command.parse(URL(string: "duskbar://effect?name=Darkroom&on=1")!), .effect(name: "darkroom", on: true))
        XCTAssertEqual(Command.parse(URL(string: "duskbar://bedtime?on=0")!), .bedtime(on: false))
        XCTAssertNil(Command.parse(URL(string: "duskbar://temp")!))
        XCTAssertNil(Command.parse(URL(string: "duskbar://effect?name=rainbow")!))
        XCTAssertNil(Command.parse(URL(string: "https://disable")!))
    }

    func testFluxImport() {
        XCTAssertEqual(FluxImport.read([:]), .init())
        XCTAssertEqual(FluxImport.read(["dayColorTemp": 3900, "nightColorTemp": "3500", "lateColorTemp": 2000, "wakeTime": 480]),
                       .init(dayK: 3900, nightK: 3500, lateK: 2000, wakeMinutes: 480))
        XCTAssertEqual(FluxImport.read(["dayColorTemp": "abc", "nightColorTemp": 99999, "wakeTime": -5]), .init())
    }

    func testZoneTab() {
        let text = try! String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8)
        let c = ZoneTab.city(for: "America/Chicago", in: text)!
        XCTAssertEqual(c.name, "Chicago")
        XCTAssertEqual(c.lat, 41.85, accuracy: 0.01)
        XCTAssertEqual(c.lon, -87.65, accuracy: 0.01)
        XCTAssertEqual(ZoneTab.city(for: "America/New_York", in: text)?.lat ?? 0, 40.71, accuracy: 0.01)
        XCTAssertNil(ZoneTab.city(for: "Mars/Olympus", in: text))
        XCTAssertEqual(ZoneTab.nearest(lat: 52.1, lon: 5.1, in: text)?.name, "Amsterdam")
        XCTAssertEqual(ZoneTab.nearest(lat: 41.9, lon: -87.6, in: text)?.name, "Chicago")
    }

    func testAmbient() {
        XCTAssertEqual(Ambient.darkness(lux: 500), 0)
        XCTAssertEqual(Ambient.darkness(lux: 2), 1)
        XCTAssertEqual(Ambient.darkness(lux: sqrt(2000)), 0.5, accuracy: 0.001)
    }

    func testSmootherIgnoresShortBlip() {
        var sm = Smoother(window: 120)
        let t = Date()
        for i in 0..<4 { _ = sm.add(0, at: t.addingTimeInterval(Double(i) * 30)) }
        XCTAssertEqual(sm.add(1, at: t.addingTimeInterval(120)), 0)
    }
}
