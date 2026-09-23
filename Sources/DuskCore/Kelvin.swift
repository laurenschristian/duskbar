import Foundation

struct RGB: Equatable {
    var r: Double, g: Double, b: Double
}

// Same method as Ingo Thies' Redshift table: Planckian locus below 5000 K, CIE daylight above 6500 K,
// blended between, converted to sRGB relative to D65 and gamma encoded.
enum Kelvin {
    static let range = 1000.0...10000.0
    private static let step = 100.0
    private static let table: [RGB] = stride(from: range.lowerBound, through: range.upperBound, by: step).map(compute)

    static func rgb(_ kelvin: Double) -> RGB {
        let k = min(max(kelvin, range.lowerBound), range.upperBound)
        let pos = (k - range.lowerBound) / step
        let i = min(Int(pos), table.count - 2)
        let f = pos - Double(i)
        let a = table[i], b = table[i + 1]
        return RGB(r: a.r + (b.r - a.r) * f, g: a.g + (b.g - a.g) * f, b: a.b + (b.b - a.b) * f)
    }

    private static func compute(_ t: Double) -> RGB {
        var (x, y) = planck(t)
        if t > 5000 {
            let d = daylight(t), f = min(1, (t - 5000) / 1500)
            x += (d.x - x) * f
            y += (d.y - y) * f
        }
        let X = x / y, Z = (1 - x - y) / y
        let lin = [3.2406 * X - 1.5372 - 0.4986 * Z,
                   -0.9689 * X + 1.8758 + 0.0415 * Z,
                   0.0557 * X - 0.2040 + 1.0570 * Z].map { max(0, $0) }
        let m = lin.max()!
        let c = lin.map { encode($0 / m) }
        return RGB(r: c[0], g: c[1], b: c[2])
    }

    // Planck spectrum integrated with the Wyman, Sloan and Shirley (2013) fit of the CIE 1931 observer.
    private static func planck(_ t: Double) -> (x: Double, y: Double) {
        var X = 0.0, Y = 0.0, Z = 0.0
        for l in stride(from: 360.0, through: 830.0, by: 1) {
            let lm = l * 1e-9
            let p = 1 / (pow(lm, 5) * (exp(1.4387769e-2 / (lm * t)) - 1))
            X += p * (1.056 * lobe(l, 599.8, 37.9, 31.0) + 0.362 * lobe(l, 442.0, 16.0, 26.7) - 0.065 * lobe(l, 501.1, 20.4, 26.2))
            Y += p * (0.821 * lobe(l, 568.8, 46.9, 40.5) + 0.286 * lobe(l, 530.9, 16.3, 31.1))
            Z += p * (1.217 * lobe(l, 437.0, 11.8, 36.0) + 0.681 * lobe(l, 459.0, 26.0, 13.8))
        }
        return (X / (X + Y + Z), Y / (X + Y + Z))
    }

    private static func daylight(_ t: Double) -> (x: Double, y: Double) {
        let x = t <= 7000
            ? 0.244063 + 0.09911e3 / t + 2.9678e6 / (t * t) - 4.6070e9 / (t * t * t)
            : 0.237040 + 0.24748e3 / t + 1.9018e6 / (t * t) - 2.0064e9 / (t * t * t)
        return (x, -3 * x * x + 2.87 * x - 0.275)
    }

    private static func lobe(_ x: Double, _ mu: Double, _ s1: Double, _ s2: Double) -> Double {
        let s = x < mu ? s1 : s2
        return exp(-0.5 * (x - mu) * (x - mu) / (s * s))
    }

    private static func encode(_ c: Double) -> Double {
        c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }
}
