import AppKit
import IOKit

// Private Apple APIs, loaded at runtime so a missing symbol disables one feature instead of crashing.
enum Private {
    private static let displayServices = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    private static let universalAccess = "/System/Library/PrivateFrameworks/UniversalAccess.framework/UniversalAccess"
    private static let coreBrightness = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"

    private static func sym<T>(_ lib: String, _ name: String, _: T.Type) -> T? {
        guard let handle = dlopen(lib, RTLD_LAZY), let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    private static let getBrightness = sym(displayServices, "DisplayServicesGetBrightness",
                                           (@convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32).self)
    private static let setBrightness = sym(displayServices, "DisplayServicesSetBrightness",
                                           (@convention(c) (UInt32, Float) -> Int32).self)
    private static let grayscaleSet = sym(universalAccess, "UAGrayscaleSetEnabled", (@convention(c) (Bool) -> Void).self)
    private static let grayscaleGet = sym(universalAccess, "UAGrayscaleIsEnabled", (@convention(c) () -> Bool).self)

    static func brightness(_ id: CGDirectDisplayID) -> Float? {
        var v: Float = 0
        guard let f = getBrightness, f(id, &v) == 0 else { return nil }
        return v
    }

    static func setBrightness(_ id: CGDirectDisplayID, _ v: Float) {
        _ = setBrightness?(id, min(1, max(0, v)))
    }

    static var grayscaleAvailable: Bool { grayscaleSet != nil && grayscaleGet != nil }
    static var grayscale: Bool {
        get { grayscaleGet?() ?? false }
        set { grayscaleSet?(newValue) }
    }

    // MARK: CoreBrightness

    private static let brightnessLoaded = dlopen(coreBrightness, RTLD_LAZY) != nil

    private static let keyboardClient: NSObject? = {
        guard brightnessLoaded, let c = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        return c.init()
    }()

    private static var keyboardID: UInt64? {
        let sel = NSSelectorFromString("copyKeyboardBacklightIDs")
        guard let k = keyboardClient, k.responds(to: sel),
              let ids = k.perform(sel)?.takeRetainedValue() as? [NSNumber] else { return nil }
        return ids.first?.uint64Value
    }

    static var keyboardBrightness: Float? {
        get {
            let sel = NSSelectorFromString("brightnessForKeyboard:")
            guard let k = keyboardClient, let id = keyboardID, k.responds(to: sel) else { return nil }
            typealias F = @convention(c) (AnyObject, Selector, UInt64) -> Float
            return unsafeBitCast(k.method(for: sel), to: F.self)(k, sel, id)
        }
        set {
            let sel = NSSelectorFromString("setBrightness:forKeyboard:")
            guard let v = newValue, let k = keyboardClient, let id = keyboardID, k.responds(to: sel) else { return }
            typealias F = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
            _ = unsafeBitCast(k.method(for: sel), to: F.self)(k, sel, min(1, max(0, v)), id)
        }
    }

    /// True when Night Shift is tinting the screen right now.
    static var nightShiftOn: Bool {
        let sel = NSSelectorFromString("getBlueLightStatus:")
        guard brightnessLoaded, let c = NSClassFromString("CBBlueLightClient") as? NSObject.Type else { return false }
        let client = c.init()
        guard client.responds(to: sel) else { return false }
        typealias F = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
        // StatusData starts with BOOL active, BOOL enabled; the buffer is larger than the struct.
        var buf = [UInt8](repeating: 0, count: 64)
        let ok = buf.withUnsafeMutableBytes { unsafeBitCast(client.method(for: sel), to: F.self)(client, sel, $0.baseAddress!) }
        return ok && buf[1] != 0
    }

    static var gammaBrokenChip: Bool {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        let brand = String(cString: buf)
        return brand.contains("M5 Pro") || brand.contains("M5 Max")
    }
}

/// Built-in ambient light sensor. The SPU driver publishes CurrentLux in the IORegistry (public API, no HID client).
final class LightSensor {
    private lazy var entry: io_registry_entry_t? = {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        while case let e = IOIteratorNext(it), e != 0 {
            if lux(of: e) != nil { return e }
            IOObjectRelease(e)
        }
        return nil
    }()

    var available: Bool { entry != nil }
    var lux: Double? { entry.flatMap(lux(of:)) }

    private func lux(of e: io_registry_entry_t) -> Double? {
        (IORegistryEntrySearchCFProperty(e, kIOServicePlane, "CurrentLux" as CFString, nil,
                                         IOOptionBits(kIORegistryIterateRecursively)) as? NSNumber)?.doubleValue
    }
}
