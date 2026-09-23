import Foundation

// NOAA solar position algorithm (https://gml.noaa.gov/grad/solcalc/calcdetails.html), no refraction.
enum Solar {
    static func elevation(at date: Date, lat: Double, lon: Double) -> Double {
        let jd = date.timeIntervalSince1970 / 86400 + 2_440_587.5
        let jc = (jd - 2_451_545) / 36525
        let meanLong = (280.46646 + jc * (36000.76983 + jc * 0.0003032)).truncatingRemainder(dividingBy: 360)
        let meanAnom = 357.52911 + jc * (35999.05029 - 0.0001537 * jc)
        let ecc = 0.016708634 - jc * (0.000042037 + 0.0000001267 * jc)
        let m = rad(meanAnom)
        let center = sin(m) * (1.914602 - jc * (0.004817 + 0.000014 * jc))
            + sin(2 * m) * (0.019993 - 0.000101 * jc) + sin(3 * m) * 0.000289
        let omega = rad(125.04 - 1934.136 * jc)
        let appLong = meanLong + center - 0.00569 - 0.00478 * sin(omega)
        let meanObliq = 23 + (26 + (21.448 - jc * (46.815 + jc * (0.00059 - jc * 0.001813))) / 60) / 60
        let obliq = rad(meanObliq + 0.00256 * cos(omega))
        let decl = asin(sin(obliq) * sin(rad(appLong)))
        let y = pow(tan(obliq / 2), 2)
        let l0 = rad(meanLong)
        let eqTime = 4 * deg(y * sin(2 * l0) - 2 * ecc * sin(m) + 4 * ecc * y * sin(m) * cos(2 * l0)
            - 0.5 * y * y * sin(4 * l0) - 1.25 * ecc * ecc * sin(2 * m))
        let utcMinutes = (date.timeIntervalSince1970 / 60).truncatingRemainder(dividingBy: 1440)
        var tst = (utcMinutes + eqTime + 4 * lon).truncatingRemainder(dividingBy: 1440)
        if tst < 0 { tst += 1440 }
        let hourAngle = rad(tst / 4 < 0 ? tst / 4 + 180 : tst / 4 - 180)
        let phi = rad(lat)
        let cosZenith = sin(phi) * sin(decl) + cos(phi) * cos(decl) * cos(hourAngle)
        return 90 - deg(acos(max(-1, min(1, cosZenith))))
    }

    static func isRising(at date: Date, lat: Double, lon: Double) -> Bool {
        elevation(at: date.addingTimeInterval(60), lat: lat, lon: lon) > elevation(at: date, lat: lat, lon: lon)
    }

    /// First time after `date` the sun crosses `threshold` degrees in the given direction, or nil if it does not within `window`.
    static func nextCrossing(after date: Date, lat: Double, lon: Double, threshold: Double, rising: Bool,
                             window: TimeInterval = 36 * 3600) -> Date? {
        let step: TimeInterval = 600
        var t0 = date, e0 = elevation(at: t0, lat: lat, lon: lon) - threshold
        while t0.timeIntervalSince(date) < window {
            let t1 = t0.addingTimeInterval(step)
            let e1 = elevation(at: t1, lat: lat, lon: lon) - threshold
            if rising ? (e0 < 0 && e1 >= 0) : (e0 > 0 && e1 <= 0) {
                var lo = t0, hi = t1
                for _ in 0..<20 {
                    let mid = lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
                    let em = elevation(at: mid, lat: lat, lon: lon) - threshold
                    if (em >= 0) == rising { hi = mid } else { lo = mid }
                }
                return hi
            }
            t0 = t1; e0 = e1
        }
        return nil
    }

    private static func rad(_ d: Double) -> Double { d * .pi / 180 }
    private static func deg(_ r: Double) -> Double { r * 180 / .pi }
}
