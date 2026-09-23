import Foundation

enum Command: Equatable {
    case disable(minutes: Double?)
    case enable
    case temp(kelvin: Double, minutes: Double)
    case effect(name: String, on: Bool?)
    case bedtime(on: Bool)

    static let effects: Set = ["darkroom", "dim", "grayscale"]

    static func parse(_ url: URL) -> Command? {
        guard url.scheme == "duskbar", let host = url.host?.lowercased() else { return nil }
        var q: [String: String] = [:]
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.forEach { q[$0.name.lowercased()] = $0.value }
        let minutes = q["minutes"].flatMap(Double.init).map { min(max($0, 1), 1440) }
        switch host {
        case "disable": return .disable(minutes: minutes)
        case "enable": return .enable
        case "temp":
            guard let k = q["k"].flatMap(Double.init) else { return nil }
            return .temp(kelvin: min(max(k, 1200), 6500), minutes: minutes ?? 60)
        case "effect":
            guard let name = q["name"]?.lowercased(), effects.contains(name) else { return nil }
            return .effect(name: name, on: q["on"].map { $0 == "1" || $0 == "true" })
        case "bedtime": return .bedtime(on: q["on"].map { $0 == "1" || $0 == "true" } ?? true)
        default: return nil
        }
    }
}

enum FluxImport {
    struct Result: Equatable {
        var dayK: Double?, nightK: Double?, lateK: Double?, wakeMinutes: Int?
    }

    static func read(_ d: [String: Any]) -> Result {
        func temp(_ key: String) -> Double? {
            guard let v = number(d[key]), (1000...10000).contains(v) else { return nil }
            return v
        }
        let wake = number(d["wakeTime"]).flatMap { (0..<1440).contains($0) ? Int($0) : nil }
        return Result(dayK: temp("dayColorTemp"), nightK: temp("nightColorTemp"), lateK: temp("lateColorTemp"), wakeMinutes: wake)
    }

    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
}

enum ZoneTab {
    struct City: Equatable {
        var name: String, lat: Double, lon: Double
    }

    static func city(for identifier: String, in text: String) -> City? {
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let cols = line.split(separator: "\t")
            guard cols.count >= 3, cols[2] == identifier, let (lat, lon) = coordinates(String(cols[1])) else { continue }
            let name = identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? identifier
            return City(name: name, lat: lat, lon: lon)
        }
        return nil
    }

    /// Closest zone.tab city, used to name a GPS fix without a network geocoder.
    static func nearest(lat: Double, lon: Double, in text: String) -> City? {
        var best: (City, Double)?
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let cols = line.split(separator: "\t")
            guard cols.count >= 3, let (la, lo) = coordinates(String(cols[1])) else { continue }
            let dLon = (lon - lo) * cos(lat * .pi / 180)
            let d = (lat - la) * (lat - la) + dLon * dLon
            if best == nil || d < best!.1 {
                let name = cols[2].split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? String(cols[2])
                best = (City(name: name, lat: la, lon: lo), d)
            }
        }
        return best?.0
    }

    /// ISO 6709 as in zone.tab: +DDMM+DDDMM or +DDMMSS+DDDMMSS.
    static func coordinates(_ s: String) -> (Double, Double)? {
        guard let split = s.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
        let latPart = String(s[..<split]), lonPart = String(s[split...])
        guard let lat = angle(latPart, degreeDigits: 2), let lon = angle(lonPart, degreeDigits: 3) else { return nil }
        return (lat, lon)
    }

    private static func angle(_ s: String, degreeDigits: Int) -> Double? {
        guard let sign = s.first, sign == "+" || sign == "-" else { return nil }
        let digits = Array(s.dropFirst())
        guard digits.count == degreeDigits + 2 || digits.count == degreeDigits + 4, digits.allSatisfy(\.isNumber) else { return nil }
        let n = digits.map { Double(String($0))! }
        func value(_ r: Range<Int>) -> Double { r.reduce(0) { $0 * 10 + n[$1] } }
        var v = value(0..<degreeDigits) + value(degreeDigits..<degreeDigits + 2) / 60
        if digits.count == degreeDigits + 4 { v += value(degreeDigits + 2..<degreeDigits + 4) / 3600 }
        return sign == "-" ? -v : v
    }
}

enum Ambient {
    static let brightLux = 200.0
    static let darkLux = 10.0

    static func darkness(lux: Double) -> Double {
        if lux >= brightLux { return 0 }
        if lux <= darkLux { return 1 }
        return (log(brightLux) - log(lux)) / (log(brightLux) - log(darkLux))
    }
}

/// Time-windowed median, so a hand over the sensor for a few seconds changes nothing.
struct Smoother {
    let window: TimeInterval
    private var samples: [(Date, Double)] = []

    init(window: TimeInterval) { self.window = window }

    mutating func add(_ value: Double, at t: Date) -> Double {
        samples.append((t, value))
        samples.removeAll { t.timeIntervalSince($0.0) > window }
        let sorted = samples.map(\.1).sorted()
        return sorted[sorted.count / 2]
    }
}
