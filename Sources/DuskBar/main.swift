import AppKit
import Carbon.HIToolbox
import CoreLocation
import ServiceManagement
import UserNotifications

private let defaults = UserDefaults.standard
private let temperatures: [Double] = [1200, 1900, 2300, 2700, 3000, 3400, 3900, 4200, 5000, 5500, 6500]
private let readme = "https://github.com/laurenschristian/duskbar#troubleshooting"

final class DuskBar: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let displays = Displays()
    private let locator = Locator()
    private let weather = Weather()
    private let sensor = LightSensor()
    private var smoother = Smoother(window: 120)

    private var launched = false
    private var settings = Settings() { didSet { save(settings, "settings"); settingsChanged() } }
    private var calendar = Calendar.current

    // Overrides
    private var pausedUntil: Date?
    private var hold: (kelvin: Double, until: Date)?
    private var forcedBedtimeUntil: Date?
    private var appPaused = false
    private var darkness = 0.0

    // Output state
    private var applied: (kelvin: Double, dim: Double)?
    private var appliedDarkroom = false
    private var lastState: ColorState?
    private var fade: DispatchSourceTimer?
    private var tick: DispatchSourceTimer?
    private var sensorTimer: DispatchSourceTimer?
    private var weatherTimer: DispatchSourceTimer?
    private var reconfigWork: DispatchWorkItem?
    private var conflict = false
    private var notice: String?
    private var hotkeys: [EventHotKeyRef?] = []

    // Backlight and keyboard: the day value, what we last set, and whether the user took over.
    // Persisted so a crash at night does not make the dimmed value the new day value.
    private var backlightBase: [CGDirectDisplayID: Float] = [:] {
        didSet { defaults.set(Dictionary(uniqueKeysWithValues: backlightBase.map { (String($0.key), $0.value) }), forKey: "backlightBase") }
    }
    private var backlightSet: [CGDirectDisplayID: Float] = [:]
    private var backlightManual: Set<CGDirectDisplayID> = []
    private var keyboardBase: Float? { didSet { defaults.set(keyboardBase, forKey: "keyboardBase") } }
    private var keyboardSet: Float?
    private var keyboardManual = false
    private var darkModeWanted: Bool?
    private var darkModeManualAt: Date?
    private var darkModeSetAt: Date?

    // MARK: Stored options

    private func flag(_ key: String, _ fallback: Bool = false) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
    private var darkroom: Bool { get { flag("darkroom") } set { defaults.set(newValue, forKey: "darkroom") } }
    private var dimLevel: Double { get { defaults.object(forKey: "dimLevel") as? Double ?? 1 } set { defaults.set(newValue, forKey: "dimLevel") } }
    private var ambientOn: Bool { get { flag("ambient") } set { defaults.set(newValue, forKey: "ambient") } }
    private var weatherOn: Bool { get { flag("weather") } set { defaults.set(newValue, forKey: "weather") } }
    private var darkModeOn: Bool { get { flag("darkMode") } set { defaults.set(newValue, forKey: "darkMode") } }
    private var backlightNight: Double { get { defaults.object(forKey: "backlightNight") as? Double ?? 1 } set { defaults.set(newValue, forKey: "backlightNight") } }
    private var keyboardOn: Bool { get { flag("keyboard") } set { defaults.set(newValue, forKey: "keyboard") } }
    private var nudgeOn: Bool { get { flag("nudge") } set { defaults.set(newValue, forKey: "nudge") } }
    private var hotkeysOn: Bool { get { flag("hotkeys", true) } set { defaults.set(newValue, forKey: "hotkeys") } }
    private var fullscreenPause: Bool { get { flag("fullscreenPause") } set { defaults.set(newValue, forKey: "fullscreenPause") } }
    private var pausedApps: [String] { get { defaults.stringArray(forKey: "disabledApps") ?? [] } set { defaults.set(newValue, forKey: "disabledApps") } }
    private var pinned: Bool { get { flag("locationPinned") } set { defaults.set(newValue, forKey: "locationPinned") } }
    private var nudgeSkipBefore: Date? { get { defaults.object(forKey: "nudgeSkipBefore") as? Date } set { defaults.set(newValue, forKey: "nudgeSkipBefore") } }

    private struct Place: Codable { var name: String, lat: Double, lon: Double, timeZone: String? }
    private var manualPlace: Place? { get { load("manualPlace") } set { save(newValue, "manualPlace") } }
    private var fixPlace: Place? { get { load("fixPlace") } set { save(newValue, "fixPlace") } }

    private lazy var zoneTab = (try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8)) ?? ""

    private var place: (Place, String) {
        if pinned, let p = manualPlace { return (p, "set by you") }
        let tz = TimeZone.current.identifier
        if let p = fixPlace, p.timeZone == tz { return (p, "located") }
        if let c = ZoneTab.city(for: tz, in: zoneTab) { return (Place(name: c.name, lat: c.lat, lon: c.lon, timeZone: tz), "time zone") }
        return (Place(name: "Greenwich", lat: 51.48, lon: 0, timeZone: nil), "fallback")
    }

    private var inputs: Inputs {
        let p = place.0
        return Inputs(lat: p.lat, lon: p.lon, cloudCover: weatherOn ? weather.current : nil, darkness: ambientOn ? darkness : 0)
    }

    // MARK: Launch

    func applicationWillFinishLaunching(_: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_: Notification) {
        settings = load("settings") ?? importFlux()
        let savedBase = defaults.dictionary(forKey: "backlightBase") as? [String: Float] ?? [:]
        backlightBase = Dictionary(uniqueKeysWithValues: savedBase.compactMap { k, v in UInt32(k).map { ($0, v) } })
        keyboardBase = defaults.object(forKey: "keyboardBase") as? Float
        menu.delegate = self
        status.menu = menu
        status.button?.imagePosition = .imageLeading

        locator.onFix = { [weak self] fix in self?.gotFix(fix) }
        Nudge.setUp(delegate: self)
        installHotkeyHandler()
        if hotkeysOn { registerHotkeys() }
        observe()
        if !pinned, fixPlace?.timeZone != TimeZone.current.identifier { locator.requestFix() }
        launched = true
        restartSensors()
        settingsChanged()
        refresh(fade: 0)
    }

    func applicationWillTerminate(_: Notification) {
        displays.restore()
        restoreBacklight()
        restoreKeyboard()
    }

    /// Takes the user's f.lux temperatures and wake time on first launch.
    private func importFlux() -> Settings {
        var s = Settings()
        guard let d = UserDefaults(suiteName: "org.herf.Flux")?.dictionaryRepresentation() else { return s }
        let r = FluxImport.read(d)
        s.dayK = r.dayK ?? s.dayK
        s.nightK = r.nightK ?? s.nightK
        s.lateK = r.lateK ?? s.lateK
        s.wakeMinutes = r.wakeMinutes ?? s.wakeMinutes
        return s
    }

    private func observe() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.woke() }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.woke()
            self?.restartSensors()
        }
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sensorTimer?.cancel()
            self?.sensorTimer = nil
        }
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.checkFrontmost()
        }
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.checkFrontmost()
        }
        let nc = NotificationCenter.default
        nc.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in self?.timeZoneChanged() }
        nc.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in self?.refresh(fade: 0) }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                                                            object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(darkModeSetAt ?? .distantPast) > 5 { darkModeManualAt = Date() }
        }
        CGDisplayRegisterReconfigurationCallback({ _, flags, context in
            guard !flags.contains(.beginConfigurationFlag), let context else { return }
            let app = Unmanaged<DuskBar>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { app.displaysChanged() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func woke() {
        if place.0.timeZone != nil, place.0.timeZone != TimeZone.current.identifier { timeZoneChanged() }
        displays.invalidate()
        refresh(fade: 0)
    }

    // The callback fires before display services are ready, so wait before reapplying.
    private func displaysChanged() {
        reconfigWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.displays.invalidate()
            self?.refresh(fade: 0)
        }
        reconfigWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func timeZoneChanged() {
        NSTimeZone.resetSystemTimeZone()
        calendar = Calendar.current
        if !pinned {
            notice = "Location updated: \(place.0.name)"
            locator.requestFix()
        }
        settingsChanged()
    }

    private func gotFix(_ fix: CLLocation) {
        let lat = fix.coordinate.latitude, lon = fix.coordinate.longitude
        let name = Self.coordinates(lat, lon)
        let moved = fixPlace.map { abs($0.lat - lat) > 0.5 || abs($0.lon - lon) > 0.5 } ?? true
        fixPlace = Place(name: name, lat: lat, lon: lon, timeZone: TimeZone.current.identifier)
        if moved, !pinned { notice = "Location updated: \(name)" }
        refresh(fade: 1)
    }

    private func settingsChanged() {
        guard launched else { return }
        if nudgeOn {
            Nudge.schedule(bedtimeMinutes: settings.bedtimeMinutes, calendar: calendar, skipBefore: nudgeSkipBefore)
        }
        refresh(fade: 1)
    }

    // MARK: Color

    private func target(at now: Date) -> (kelvin: Double, dim: Double, state: ColorState) {
        var st = Blend.state(at: now, settings: settings, inputs: inputs, calendar: calendar)
        if let until = forcedBedtimeUntil {
            if now < until {
                st.late = 1
                st.kelvin = min(st.kelvin, settings.lateK)
            } else {
                forcedBedtimeUntil = nil
            }
        }
        var k = st.kelvin
        if let h = hold {
            if now < h.until { k = h.kelvin } else { hold = nil }
        }
        if let until = pausedUntil, now >= until { pausedUntil = nil }
        if pausedUntil != nil || appPaused { k = 6500 }
        return (k, st.dim * dimLevel, st)
    }

    private var isPaused: Bool { pausedUntil != nil || appPaused }

    /// Recomputes the color and applies it, fading over `fade` seconds when the jump is large.
    private func refresh(fade seconds: TimeInterval) {
        let now = Date()
        let t = target(at: now)
        lastState = t.state
        let from = applied ?? (t.kelvin, t.dim)
        let jump = abs(from.kelvin - t.kelvin) > 100 || abs(from.dim - t.dim) > 0.05
        if seconds > 0, jump, appliedDarkroom == darkroom {
            animate(from: from, to: (t.kelvin, t.dim), over: seconds)
        } else {
            fade?.cancel()
            write(t.kelvin, t.dim)
        }
        applyExtras(t.state)
        updateIcon()
        scheduleTick(after: now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.checkConflicts() }
    }

    private func write(_ kelvin: Double, _ dim: Double) {
        displays.apply(GammaTable(kelvin: kelvin, dim: dim, darkroom: darkroom))
        applied = (kelvin, dim)
        appliedDarkroom = darkroom
    }

    private func animate(from: (kelvin: Double, dim: Double), to: (kelvin: Double, dim: Double), over seconds: TimeInterval) {
        fade?.cancel()
        let start = Date()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            let p = min(1, Date().timeIntervalSince(start) / seconds)
            let e = p * p * (3 - 2 * p)
            self?.write(from.kelvin + (to.kelvin - from.kelvin) * e, from.dim + (to.dim - from.dim) * e)
            if p >= 1 { self?.fade?.cancel() }
        }
        fade = timer
        timer.resume()
    }

    private func scheduleTick(after now: Date) {
        tick?.cancel()
        var next: Date
        if Schedule.inTransition(at: now, settings: settings, inputs: inputs, calendar: calendar) {
            next = now.addingTimeInterval(10)
        } else {
            next = Schedule.nextChange(after: now, settings: settings, inputs: inputs, calendar: calendar) ?? now.addingTimeInterval(6 * 3600)
        }
        for d in [pausedUntil, hold?.until, forcedBedtimeUntil].compactMap({ $0 }) where d > now { next = min(next, d) }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(wallDeadline: .now() + max(1, next.timeIntervalSince(now)), leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.refresh(fade: self?.settings.fastTransitions == true ? 20 : 1) }
        tick = timer
        timer.resume()
    }

    private func checkConflicts() {
        conflict = !displays.conflicted().isEmpty
        updateIcon()
    }

    private func updateIcon() {
        let name: String
        if conflict { name = "exclamationmark.triangle" }
        else if isPaused { name = "circle.slash" }
        else {
            switch lastState?.phase ?? .day {
            case .day, .boost: name = "sun.max"
            case .sunset: name = "sunset"
            case .bedtime: name = "moon"
            }
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "DuskBar")
        image?.isTemplate = true
        status.button?.image = image
    }

    // MARK: Backlight, keyboard, dark mode

    private func applyExtras(_ st: ColorState) {
        let dark = isPaused ? 0 : st.darkness
        applyBacklight(dark)
        applyKeyboard(dark)
        applyDarkMode(st.darkness >= 0.5)
    }

    private func applyBacklight(_ dark: Double) {
        guard backlightNight < 1 else { return restoreBacklight() }
        let factor = Float(1 - (1 - backlightNight) * dark)
        for id in displays.online {
            guard let current = Private.brightness(id) else { continue }
            if let last = backlightSet[id], abs(current - last) > 0.02 { backlightManual.insert(id) }
            if dark == 0 {
                if !backlightManual.contains(id), let base = backlightBase[id] { Private.setBrightness(id, base) }
                backlightBase[id] = nil
                backlightSet[id] = nil
                backlightManual.remove(id)
                continue
            }
            if backlightManual.contains(id) { continue }
            let base = backlightBase[id] ?? current
            backlightBase[id] = base
            let v = base * factor
            if abs(v - current) > 0.004 { Private.setBrightness(id, v) }
            backlightSet[id] = v
        }
    }

    private func restoreBacklight() {
        for (id, base) in backlightBase where !backlightManual.contains(id) { Private.setBrightness(id, base) }
        backlightBase.removeAll()
        backlightSet.removeAll()
        backlightManual.removeAll()
    }

    private func applyKeyboard(_ dark: Double) {
        guard keyboardOn, let current = Private.keyboardBrightness else { return restoreKeyboard() }
        if let last = keyboardSet, abs(current - last) > 0.02 { keyboardManual = true }
        if dark == 0 {
            restoreKeyboard()
            return
        }
        if keyboardManual { return }
        let base = keyboardBase ?? current
        keyboardBase = base
        let v = base * Float(1 - 0.7 * dark)
        if abs(v - current) > 0.004 { Private.keyboardBrightness = v }
        keyboardSet = v
    }

    private func restoreKeyboard() {
        if !keyboardManual, let base = keyboardBase { Private.keyboardBrightness = base }
        keyboardBase = nil
        keyboardSet = nil
        keyboardManual = false
    }

    private func applyDarkMode(_ want: Bool) {
        guard darkModeOn else { darkModeWanted = nil; return }
        defer { darkModeWanted = want }
        guard want != darkModeWanted else { return }
        if let manual = darkModeManualAt, Date().timeIntervalSince(manual) < 2 * 3600 { return }
        if Appearance.isDark != want {
            darkModeSetAt = Date()
            Appearance.set(dark: want)
        }
    }

    // MARK: Sensors

    private func restartSensors() {
        sensorTimer?.cancel()
        sensorTimer = nil
        if ambientOn, sensor.available {
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now(), repeating: 30, leeway: .seconds(5))
            t.setEventHandler { [weak self] in self?.readSensor() }
            sensorTimer = t
            t.resume()
        } else if darkness != 0 {
            darkness = 0
            refresh(fade: 1)
        }
        weatherTimer?.cancel()
        weatherTimer = nil
        if weatherOn {
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now(), repeating: 3600, leeway: .seconds(60))
            t.setEventHandler { [weak self] in
                guard let self else { return }
                let p = place.0
                weather.fetch(lat: p.lat, lon: p.lon) { [weak self] in self?.refresh(fade: 1) }
            }
            weatherTimer = t
            t.resume()
        }
    }

    private func readSensor() {
        guard let lux = sensor.lux else { return }
        let d = smoother.add(Ambient.darkness(lux: lux), at: Date())
        if abs(d - darkness) > 0.02 {
            darkness = d
            refresh(fade: 2)
        }
    }

    // MARK: Pausing

    private func checkFrontmost() {
        let app = NSWorkspace.shared.frontmostApplication
        var paused = app?.bundleIdentifier.map(pausedApps.contains) ?? false
        if !paused, fullscreenPause, let pid = app?.processIdentifier { paused = isFullscreen(pid) }
        guard paused != appPaused else { return }
        appPaused = paused
        refresh(fade: 1)
    }

    private func isFullscreen(_ pid: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let screens = NSScreen.screens.map(\.frame.size)
        return windows.contains { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return screens.contains { $0.width == b["Width"] && $0.height == b["Height"] }
        }
    }

    private func pause(minutes: Double?) {
        pausedUntil = Date().addingTimeInterval((minutes ?? 60) * 60)
        refresh(fade: 1)
    }

    private func resume() {
        pausedUntil = nil
        hold = nil
        forcedBedtimeUntil = nil
        refresh(fade: 1)
    }

    private var nextSunrise: Date {
        let p = place.0
        return Solar.nextCrossing(after: Date(), lat: p.lat, lon: p.lon, threshold: Blend.dayElevation, rising: true)
            ?? Date().addingTimeInterval(12 * 3600)
    }

    private var nextWake: Date {
        let now = Date()
        let today = calendar.date(bySettingHour: settings.wakeMinutes / 60, minute: settings.wakeMinutes % 60, second: 0, of: now) ?? now
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }

    private var holdUntil: Date {
        Schedule.nextChange(after: Date(), settings: settings, inputs: inputs, calendar: calendar) ?? Date().addingTimeInterval(3 * 3600)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date()
        let t = target(at: now)
        let time = DateFormatter()
        time.timeStyle = .short
        time.dateStyle = .none

        var header = "\(Int(t.kelvin.rounded()))K, \(t.state.phase.rawValue)"
        if let until = pausedUntil { header = "Paused until \(time.string(from: until))" }
        else if appPaused { header = "Paused for \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "this app")" }
        else if let h = hold { header = "\(Int(h.kelvin))K until \(time.string(from: h.until))" }
        menu.addItem(label(header))
        if let next = Schedule.nextTarget(after: now, settings: settings, inputs: inputs, calendar: calendar) {
            menu.addItem(label("Next: \(Int(next.state.kelvin.rounded()))K from \(time.string(from: next.start))"))
        }
        let (p, source) = place
        menu.addItem(label("Location: \(p.name) (\(source))"))
        if let notice { menu.addItem(label(notice)) }
        notice = nil

        let slider = SliderItem(kelvin: t.kelvin)
        slider.onChange = { [weak self] k, _ in
            guard let self else { return }
            hold = (k, holdUntil)
            fade?.cancel()
            write(k, t.dim)
        }
        let sliderItem = NSMenuItem()
        sliderItem.view = slider
        menu.addItem(sliderItem)
        menu.addItem(.separator())

        if isPaused || hold != nil || forcedBedtimeUntil != nil { menu.addItem(item("Resume Schedule") { $0.resume() }) }
        menu.addItem(item("Pause for 1 Hour", key: "\u{2325}\u{2318}End") { $0.pause(minutes: 60) })
        menu.addItem(item("Pause Until Sunrise") { app in
            app.pausedUntil = app.nextSunrise
            app.refresh(fade: 1)
        })
        if let front = NSWorkspace.shared.frontmostApplication, let id = front.bundleIdentifier, id != Bundle.main.bundleIdentifier {
            menu.addItem(item("Pause for \(front.localizedName ?? id)", on: pausedApps.contains(id)) { app in
                app.pausedApps = app.pausedApps.contains(id) ? app.pausedApps.filter { $0 != id } : app.pausedApps + [id]
                app.checkFrontmost()
            })
        }
        menu.addItem(item("Pause for Fullscreen Apps", on: fullscreenPause) { app in
            app.fullscreenPause.toggle()
            app.checkFrontmost()
        })
        menu.addItem(.separator())

        menu.addItem(submenu("Effects", effectsMenu()))
        menu.addItem(submenu("Schedule", scheduleMenu(time)))
        menu.addItem(submenu("Location", locationMenu()))
        menu.addItem(submenu("Sensors", sensorsMenu()))
        menu.addItem(submenu("Evening", eveningMenu()))

        let warnings = self.warnings()
        if !warnings.isEmpty {
            menu.addItem(.separator())
            for w in warnings {
                menu.addItem(item("\u{26A0}\u{FE0E} \(w)") { _ in NSWorkspace.shared.open(URL(string: readme)!) })
            }
        }

        menu.addItem(.separator())
        menu.addItem(item("Hotkeys Enabled", on: hotkeysOn) { app in
            app.hotkeysOn.toggle()
            app.hotkeysOn ? app.registerHotkeys() : app.unregisterHotkeys()
        })
        menu.addItem(item("Launch at Login", on: SMAppService.mainApp.status == .enabled) { _ in
            let s = SMAppService.mainApp
            try? s.status == .enabled ? s.unregister() : s.register()
        })
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        menu.addItem(label("DuskBar \(version)"))
        let quit = NSMenuItem(title: "Quit DuskBar", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func warnings() -> [String] {
        var w: [String] = []
        if conflict { w.append("Another app is changing screen color") }
        if Private.nightShiftOn { w.append("Night Shift is on and stacks with DuskBar") }
        for id in displays.unsupported { w.append("\(Displays.name(id)): not supported") }
        if Private.gammaBrokenChip { w.append("M5 Pro/Max: macOS may ignore color changes") }
        return w
    }

    private func effectsMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item("Darkroom", key: "\u{2325}\u{2318}Home", on: darkroom) { $0.toggleDarkroom() })
        let dim = NSMenu()
        for (title, v) in [("Off", 1.0), ("80%", 0.8), ("60%", 0.6), ("45%", 0.45), ("30%", 0.3)] {
            dim.addItem(item(title, on: abs(dimLevel - v) < 0.01) { app in
                app.dimLevel = v
                app.refresh(fade: 1)
            })
        }
        m.addItem(submenu("Dim Below Minimum", dim))
        let gray = item("Grayscale", on: Private.grayscale) { _ in Private.grayscale.toggle() }
        gray.isEnabled = Private.grayscaleAvailable
        m.addItem(gray)
        m.addItem(.separator())
        for (title, k) in [("Soft White (3400K)", 3400.0), ("Ember (1200K)", 1200.0)] {
            m.addItem(item(title, on: hold?.kelvin == k) { app in
                app.hold = (k, app.holdUntil)
                app.refresh(fade: 1)
            })
        }
        return m
    }

    private func scheduleMenu(_ time: DateFormatter) -> NSMenu {
        let m = NSMenu()
        m.addItem(submenu("Daytime: \(Int(settings.dayK))K", tempMenu(\.dayK)))
        m.addItem(submenu("Sunset: \(Int(settings.nightK))K", tempMenu(\.nightK)))
        m.addItem(submenu("Bedtime: \(Int(settings.lateK))K", tempMenu(\.lateK)))
        m.addItem(.separator())
        let wake = NSMenu()
        for minutes in stride(from: 4 * 60, through: 11 * 60, by: 30) {
            wake.addItem(item(clock(minutes), on: settings.wakeMinutes == minutes) { $0.settings.wakeMinutes = minutes })
        }
        m.addItem(submenu("Wake Time: \(clock(settings.wakeMinutes))", wake))
        let sleep = NSMenu()
        for minutes in stride(from: 360, through: 600, by: 30) {
            sleep.addItem(item(String(format: "%.1f h", Double(minutes) / 60), on: settings.sleepMinutes == minutes) {
                $0.settings.sleepMinutes = minutes
            })
        }
        m.addItem(submenu("Sleep: \(String(format: "%.1f h", Double(settings.sleepMinutes) / 60)), bedtime \(clock(settings.bedtimeMinutes))", sleep))
        m.addItem(item("Bedtime Warmth", on: settings.bedtimeEnabled) { $0.settings.bedtimeEnabled.toggle() })
        m.addItem(.separator())
        m.addItem(submenu("Evening Start", offsetMenu(\.eveningOffset)))
        m.addItem(submenu("Morning End", offsetMenu(\.morningOffset)))
        m.addItem(item("Fast Transitions", on: settings.fastTransitions) { $0.settings.fastTransitions.toggle() })
        m.addItem(item("Morning Blue Boost", on: settings.boost) { $0.settings.boost.toggle() })
        return m
    }

    private func tempMenu(_ key: WritableKeyPath<Settings, Double>) -> NSMenu {
        let m = NSMenu()
        for k in temperatures {
            m.addItem(item("\(Int(k))K", on: settings[keyPath: key] == k) { $0.settings[keyPath: key] = k })
        }
        return m
    }

    private func offsetMenu(_ key: WritableKeyPath<Settings, Double>) -> NSMenu {
        let m = NSMenu()
        for v in [-60.0, -30, -15, 0, 15, 30, 60] {
            let title = v == 0 ? "On time" : "\(Int(abs(v))) min \(v < 0 ? "earlier" : "later")"
            m.addItem(item(title, on: settings[keyPath: key] == v) { $0.settings[keyPath: key] = v })
        }
        return m
    }

    private func locationMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item("Follow My Location", on: !pinned) { app in
            app.pinned = false
            app.locator.requestFix()
            app.refresh(fade: 1)
        })
        m.addItem(item("Set Location\u{2026}", on: pinned) { $0.askLocation() })
        return m
    }

    private func sensorsMenu() -> NSMenu {
        let m = NSMenu()
        let luxText = sensor.lux.map { " (\(Int($0)) lux)" } ?? ""
        let ambient = item(sensor.available ? "Ambient Light\(luxText)" : "Ambient Light (no sensor)", on: ambientOn) { app in
            app.ambientOn.toggle()
            app.restartSensors()
        }
        ambient.isEnabled = sensor.available
        m.addItem(ambient)
        let cloud = weather.current.map { " (\(Int($0))% clouds)" } ?? ""
        m.addItem(item("Weather\(cloud)", on: weatherOn) { app in
            app.weatherOn.toggle()
            app.restartSensors()
            app.refresh(fade: 1)
        })
        m.addItem(label("Weather sends your rounded location to Open-Meteo hourly"))
        return m
    }

    private func eveningMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item("Dark Mode at Sunset", on: darkModeOn) { app in
            app.darkModeOn.toggle()
            app.darkModeManualAt = nil
            app.refresh(fade: 1)
        })
        let backlight = NSMenu()
        for (title, v) in [("Off", 1.0), ("90%", 0.9), ("80%", 0.8), ("70%", 0.7), ("60%", 0.6), ("50%", 0.5)] {
            backlight.addItem(item(title, on: abs(backlightNight - v) < 0.01) { app in
                app.backlightNight = v
                app.refresh(fade: 1)
            })
        }
        m.addItem(submenu("Backlight at Night", backlight))
        m.addItem(item("Dim Keyboard at Night", on: keyboardOn) { app in
            app.keyboardOn.toggle()
            app.refresh(fade: 1)
        })
        m.addItem(item("Bedtime Reminder", on: nudgeOn) { app in
            app.nudgeOn.toggle()
            if app.nudgeOn {
                Nudge.requestAuthorization()
                app.settingsChanged()
            } else {
                Nudge.cancelAll()
            }
        })
        return m
    }

    private func askLocation() {
        let alert = NSAlert()
        alert.messageText = "Set Location"
        alert.informativeText = "Latitude, longitude. Example: 41.85, -87.65"
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        if let p = manualPlace { field.stringValue = "\(p.lat), \(p.lon)" }
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let parts = field.stringValue.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, (-90...90).contains(parts[0]), (-180...180).contains(parts[1]) else { return }
        let name = Self.coordinates(parts[0], parts[1])
        manualPlace = Place(name: name, lat: parts[0], lon: parts[1], timeZone: nil)
        pinned = true
        refresh(fade: 1)
    }

    private static func coordinates(_ lat: Double, _ lon: Double) -> String {
        String(format: "%.1f\u{00B0}%@ %.1f\u{00B0}%@", abs(lat), lat >= 0 ? "N" : "S", abs(lon), lon >= 0 ? "E" : "W")
    }

    private func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    private func label(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = sub
        return i
    }

    private final class Action: NSObject {
        let run: (DuskBar) -> Void
        init(_ run: @escaping (DuskBar) -> Void) { self.run = run }
    }

    private func item(_ title: String, key: String? = nil, on: Bool = false, _ run: @escaping (DuskBar) -> Void) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: "")
        i.target = self
        i.state = on ? .on : .off
        i.representedObject = Action(run)
        if let key { i.toolTip = key }
        return i
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        (sender.representedObject as? Action)?.run(self)
    }

    // MARK: Hotkeys and commands

    private func toggleDarkroom() {
        darkroom.toggle()
        refresh(fade: 0)
    }

    private func nudgeTemperature(by delta: Double) {
        let clamp = { (v: Double) in min(6500, max(1200, v + delta)) }
        switch lastState?.phase ?? .day {
        case .bedtime: settings.lateK = clamp(settings.lateK)
        case .sunset: settings.nightK = clamp(settings.nightK)
        case .day, .boost: settings.dayK = clamp(settings.dayK)
        }
    }

    // Carbon hotkeys need no Accessibility permission.
    private func installHotkeyHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let app = Unmanaged<DuskBar>.fromOpaque(context!).takeUnretainedValue()
            switch id.id {
            case 1: app.pausedUntil == nil ? app.pause(minutes: 60) : app.resume()
            case 2: app.nudgeTemperature(by: -200)
            case 3: app.nudgeTemperature(by: 200)
            default: app.toggleDarkroom()
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    private func registerHotkeys() {
        unregisterHotkeys()
        let mods = UInt32(cmdKey | optionKey)
        for (id, key) in [(UInt32(1), kVK_End), (2, kVK_PageUp), (3, kVK_PageDown), (4, kVK_Home)] {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(key), mods, EventHotKeyID(signature: OSType(0x4475_736B), id: id),
                                GetApplicationEventTarget(), 0, &ref)
            hotkeys.append(ref)
        }
    }

    private func unregisterHotkeys() {
        hotkeys.compactMap { $0 }.forEach { UnregisterEventHotKey($0) }
        hotkeys.removeAll()
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply _: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s),
              let command = Command.parse(url) else { return }
        switch command {
        case .disable(let minutes): pause(minutes: minutes)
        case .enable: resume()
        case .temp(let k, let minutes):
            hold = (k, Date().addingTimeInterval(minutes * 60))
            refresh(fade: 1)
        case .effect(let name, let on):
            switch name {
            case "darkroom": if on == nil || on != darkroom { toggleDarkroom() }
            case "dim":
                dimLevel = (on ?? (dimLevel == 1)) ? 0.6 : 1
                refresh(fade: 1)
            default: Private.grayscale = on ?? !Private.grayscale
            }
        case .bedtime(let on):
            forcedBedtimeUntil = on ? nextWake : nil
            refresh(fade: 1)
        }
    }

    // MARK: Notifications

    func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        DispatchQueue.main.async { [self] in
            switch response.actionIdentifier {
            case Nudge.snooze: Nudge.snooze(calendar: calendar)
            case Nudge.skip:
                nudgeSkipBefore = nextWake
                settingsChanged()
            default: break
            }
            done()
        }
    }

    // MARK: Storage

    private func save<T: Encodable>(_ value: T?, _ key: String) {
        defaults.set(value.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
    }

    private func load<T: Decodable>(_ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}

var signalSources: [DispatchSourceSignal] = []

// Restore the display on SIGTERM/SIGINT too; macOS already resets gamma when the process dies.
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { NSApp.terminate(nil) }
    source.resume()
    signalSources.append(source)
}

let app = NSApplication.shared
let delegate = DuskBar()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
