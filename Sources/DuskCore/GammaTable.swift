import Foundation

struct GammaTable: Equatable {
    static let size = 256
    var r: [Float], g: [Float], b: [Float]

    init(kelvin: Double, dim: Double = 1, darkroom: Bool = false) {
        let c = Kelvin.rgb(kelvin)
        let ramp = (0..<Self.size).map { Double($0) / Double(Self.size - 1) }
        if darkroom {
            r = ramp.map { Float((1 - $0) * dim) }
            g = Array(repeating: 0, count: Self.size)
            b = g
        } else {
            r = ramp.map { Float($0 * c.r * dim) }
            g = ramp.map { Float($0 * c.g * dim) }
            b = ramp.map { Float($0 * c.b * dim) }
        }
    }

    init(r: [Float], g: [Float], b: [Float]) {
        self.r = r; self.g = g; self.b = b
    }

    func matches(_ other: GammaTable, tolerance: Float = 0.01) -> Bool {
        guard r.count == other.r.count else { return false }
        for i in stride(from: 0, to: r.count, by: 15) where
            abs(r[i] - other.r[i]) > tolerance || abs(g[i] - other.g[i]) > tolerance || abs(b[i] - other.b[i]) > tolerance {
            return false
        }
        return true
    }
}
