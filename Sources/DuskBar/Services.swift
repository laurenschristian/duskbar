import AppKit
import CoreLocation
import UserNotifications

final class Locator: NSObject, CLLocationManagerDelegate {
    var onFix: ((CLLocation) -> Void)?
    private let manager = CLLocationManager()
    private var pending = false
    private var timeout: DispatchWorkItem?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    func requestFix() {
        pending = true
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pending = false }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorized, .authorizedAlways: manager.requestLocation()
        default: pending = false
        }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if pending, m.authorizationStatus == .authorized || m.authorizationStatus == .authorizedAlways { m.requestLocation() }
    }

    func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard pending, let fix = locations.last else { return }
        pending = false
        timeout?.cancel()
        onFix?(fix)
    }

    func locationManager(_: CLLocationManager, didFailWithError _: Error) {}
}

/// Hourly cloud cover from Open-Meteo. Only runs while weather is on.
final class Weather {
    private(set) var cloudCover: Double?
    private(set) var fetchedAt: Date?
    private let session = URLSession(configuration: .ephemeral)

    var current: Double? {
        guard let at = fetchedAt, Date().timeIntervalSince(at) < 3 * 3600 else { return nil }
        return cloudCover
    }

    func fetch(lat: Double, lon: Double, done: @escaping () -> Void) {
        let q = String(format: "latitude=%.1f&longitude=%.1f&current=cloud_cover", lat, lon)
        guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?\(q)") else { return }
        session.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = json["current"] as? [String: Any], let cover = (current["cloud_cover"] as? NSNumber)?.doubleValue
            else { return }
            DispatchQueue.main.async {
                self?.cloudCover = cover
                self?.fetchedAt = Date()
                done()
            }
        }.resume()
    }
}

enum Appearance {
    static var isDark: Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }

    static func set(dark: Bool) {
        let source = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(dark)"
        DispatchQueue.global(qos: .utility).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }
}

enum Nudge {
    static let category = "bedtime"
    static let snooze = "snooze"
    static let skip = "skip"
    private static let prefix = "duskbar.bed."

    static func setUp(delegate: UNUserNotificationCenterDelegate) {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.setNotificationCategories([UNNotificationCategory(
            identifier: category,
            actions: [UNNotificationAction(identifier: snooze, title: "Snooze 15 min"),
                      UNNotificationAction(identifier: skip, title: "Skip tonight")],
            intentIdentifiers: [])])
    }

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Schedules the 30 min warning and the bedtime notice for the next two nights, skipping `skipBefore`.
    static func schedule(bedtimeMinutes: Int, calendar: Calendar, skipBefore: Date?) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
            let now = Date()
            let midnight = calendar.startOfDay(for: now)
            for day in 0...2 {
                guard let d = calendar.date(byAdding: .day, value: day, to: midnight),
                      let bed = calendar.date(bySettingHour: bedtimeMinutes / 60, minute: bedtimeMinutes % 60, second: 0, of: d)
                else { continue }
                for (offset, body) in [(-30, "Bedtime in 30 min."), (0, "It's bedtime. The screen is warming up.")] {
                    let at = bed.addingTimeInterval(Double(offset) * 60)
                    guard at > now, skipBefore.map({ at >= $0 }) ?? true else { continue }
                    add(id: "\(prefix)\(Int(at.timeIntervalSince1970))", body: body, at: at, calendar: calendar)
                }
            }
        }
    }

    static func snooze(calendar: Calendar) {
        let at = Date().addingTimeInterval(15 * 60)
        add(id: "\(prefix)snooze", body: "Bedtime. You snoozed 15 min ago.", at: at, calendar: calendar)
    }

    static func cancelAll() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
        }
    }

    private static func add(id: String, body: String, at: Date, calendar: Calendar) {
        let content = UNMutableNotificationContent()
        content.title = "DuskBar"
        content.body = body
        content.categoryIdentifier = category
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: at)
        let request = UNNotificationRequest(identifier: id, content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
        UNUserNotificationCenter.current().add(request)
    }
}
