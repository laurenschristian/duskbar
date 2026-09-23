import AppKit

final class Displays {
    private(set) var written: [CGDirectDisplayID: GammaTable] = [:]
    private(set) var unsupported: Set<CGDirectDisplayID> = []

    var online: [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    func apply(_ table: GammaTable) {
        for id in online {
            if isVirtual(id) || CGDisplayGammaTableCapacity(id) == 0 { unsupported.insert(id); continue }
            if written[id] == table { continue }
            if CGSetDisplayTransferByTable(id, UInt32(GammaTable.size), table.r, table.g, table.b) == .success {
                written[id] = table
                unsupported.remove(id)
            } else {
                unsupported.insert(id)
            }
        }
    }

    /// Displays whose current table differs from what DuskBar wrote: another app is writing gamma.
    func conflicted() -> [CGDirectDisplayID] {
        written.compactMap { id, table in
            guard let current = read(id) else { return nil }
            return current.matches(table) ? nil : id
        }
    }

    func invalidate() { written.removeAll() }

    func restore() {
        CGDisplayRestoreColorSyncSettings()
        written.removeAll()
    }

    static func name(_ id: CGDirectDisplayID) -> String {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }?
            .localizedName ?? "Display \(id)"
    }

    private func read(_ id: CGDirectDisplayID) -> GammaTable? {
        var r = [Float](repeating: 0, count: GammaTable.size), g = r, b = r
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, UInt32(GammaTable.size), &r, &g, &b, &count) == .success,
              count == UInt32(GammaTable.size) else { return nil }
        return GammaTable(r: r, g: g, b: b)
    }

    // Sidecar, AirPlay and DisplayLink accept gamma calls but ignore them.
    private func isVirtual(_ id: CGDirectDisplayID) -> Bool {
        let name = Self.name(id).lowercased()
        return ["sidecar", "airplay", "displaylink"].contains { name.contains($0) }
    }
}
