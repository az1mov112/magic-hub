import AppKit
import CoreAudio
import AudioToolbox
import ApplicationServices
import Combine

// MARK: - Громкость (CoreAudio)

enum SystemVolume {
    private static func defaultDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return st == noErr && id != 0 ? id : nil
    }

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// Можно ли менять громкость текущего выхода (у HDMI и некоторых USB-устройств нельзя).
    static var isSettable: Bool {
        guard let dev = defaultDevice() else { return false }
        var addr = volumeAddress()
        guard AudioObjectHasProperty(dev, &addr) else { return false }
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr && settable.boolValue
    }

    static func get() -> Float? {
        guard let dev = defaultDevice() else { return nil }
        var addr = volumeAddress()
        guard AudioObjectHasProperty(dev, &addr) else { return nil }
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    @discardableResult
    static func set(_ value: Float) -> Bool {
        guard let dev = defaultDevice() else { return false }
        var addr = volumeAddress()
        var v = Float32(min(1, max(0, value)))
        return AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }

    static func isMuted() -> Bool {
        guard let dev = defaultDevice() else { return false }
        var addr = muteAddress()
        guard AudioObjectHasProperty(dev, &addr) else { return false }
        var m = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &m) == noErr && m != 0
    }

    @discardableResult
    static func setMuted(_ muted: Bool) -> Bool {
        guard let dev = defaultDevice() else { return false }
        var addr = muteAddress()
        guard AudioObjectHasProperty(dev, &addr) else { return false }
        var m = UInt32(muted ? 1 : 0)
        return AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m) == noErr
    }
}

// MARK: - Яркость встроенного экрана (приватный DisplayServices)

enum DisplayBrightness {
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getFn: GetFn? = {
        guard let h = handle, let s = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(s, to: GetFn.self)
    }()
    private static let setFn: SetFn? = {
        guard let h = handle, let s = dlsym(h, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(s, to: SetFn.self)
    }()

    static var display: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        if CGGetOnlineDisplayList(16, &ids, &count) == .success {
            for i in 0..<Int(count) where CGDisplayIsBuiltin(ids[i]) != 0 { return ids[i] }
        }
        return CGMainDisplayID()
    }

    static func get() -> Float? {
        guard let getFn else { return nil }
        var v: Float = 0
        return getFn(display, &v) == 0 ? v : nil
    }

    @discardableResult
    static func set(_ value: Float) -> Bool {
        guard let setFn else { return false }
        return setFn(display, min(1, max(0, value))) == 0
    }
}

// MARK: - Подсветка клавиатуры (приватный CoreBrightness)

enum KeyboardBacklight {
    private static let client: NSObject? = {
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        guard let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        return cls.init()
    }()

    private static let keyboardID: UInt64 = {
        guard let c = client else { return 1 }
        let sel = NSSelectorFromString("copyKeyboardBacklightIDs")
        guard c.responds(to: sel), let ids = c.perform(sel)?.takeRetainedValue() as? [NSNumber], let first = ids.first else { return 1 }
        return first.uint64Value
    }()

    static var isAvailable: Bool { return KeyboardBacklight.get() != nil }

    static func get() -> Float? {
        guard let c = client else { return nil }
        let sel = NSSelectorFromString("brightnessForKeyboard:")
        guard c.responds(to: sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, UInt64) -> Float
        let fn = unsafeBitCast(c.method(for: sel), to: Fn.self)
        return fn(c, sel, keyboardID)
    }

    @discardableResult
    static func set(_ value: Float) -> Bool {
        guard let c = client else { return false }
        let sel = NSSelectorFromString("setBrightness:forKeyboard:")
        guard c.responds(to: sel) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, Float, UInt64) -> ObjCBool
        let fn = unsafeBitCast(c.method(for: sel), to: Fn.self)
        return fn(c, sel, min(1, max(0, value)), keyboardID).boolValue
    }
}

// MARK: - Индикатор в чёлке

struct HUDEvent: Equatable {
    enum Kind { case volume, brightness, keyboard }
    var kind: Kind
    var value: Float
    var muted = false

    var icon: String {
        switch kind {
        case .volume:
            if muted || value <= 0.001 { return "speaker.slash.fill" }
            if value < 0.34 { return "speaker.wave.1.fill" }
            if value < 0.67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        case .brightness:
            return value < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .keyboard:
            return "light.max"
        }
    }
}

final class HUDModel: ObservableObject {
    static let shared = HUDModel()

    @Published private(set) var current: HUDEvent?
    private var hideWork: DispatchWorkItem?

    func show(_ event: HUDEvent) {
        current = event
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.current = nil }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

// MARK: - Перехват клавиш громкости и яркости

/// Перехватывает системные клавиши громкости/яркости/подсветки (CGEventTap), сам меняет значение
/// и показывает индикатор в чёлке — стандартное окошко macOS при этом не появляется.
/// Нужен «Универсальный доступ». Если Magic Hub закрыт — клавиши работают как обычно.
final class MediaKeyInterceptor {
    static let shared = MediaKeyInterceptor()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var waitTimer: Timer?
    private var prefsWatch: AnyCancellable?

    var isActive: Bool { tap != nil }

    func start() {
        if prefsWatch == nil {
            prefsWatch = Prefs.shared.$customHUD.dropFirst().receive(on: RunLoop.main)
                .sink { [weak self] _ in DispatchQueue.main.async { self?.start() } }
        }
        stop()
        guard Prefs.shared.customHUD else { return }
        guard AXIsProcessTrusted() else {
            // Ждём, пока пользователь выдаст «Универсальный доступ», и включаемся сами.
            waitTimer?.invalidate()
            waitTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
                if AXIsProcessTrusted() {
                    t.invalidate()
                    self?.start()
                }
            }
            return
        }
        let mask = CGEventMask(1 << 14)   // NX_SYSDEFINED
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<MediaKeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        waitTimer?.invalidate()
        waitTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let data1 = ns.data1
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyState = (data1 & 0x0000FF00) >> 8
        let isDown = keyState == 0x0A
        let fine = ns.modifierFlags.contains(.shift) && ns.modifierFlags.contains(.option)
        let step: Float = fine ? 1.0 / 64.0 : 1.0 / 16.0

        switch keyCode {
        case 0, 1, 7:   // громкость +, −, без звука
            guard SystemVolume.isSettable else { return Unmanaged.passUnretained(event) }
            if isDown { DispatchQueue.main.async { self.volume(keyCode, step: step) } }
            return nil
        case 2, 3:      // яркость +, −
            guard DisplayBrightness.get() != nil else { return Unmanaged.passUnretained(event) }
            if isDown { DispatchQueue.main.async { self.brightness(up: keyCode == 2, step: step) } }
            return nil
        case 21, 22, 23:   // подсветка клавиатуры +, −, вкл/выкл
            guard KeyboardBacklight.isAvailable else { return Unmanaged.passUnretained(event) }
            if isDown { DispatchQueue.main.async { self.keyboard(keyCode, step: step) } }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func volume(_ code: Int, step: Float) {
        var v = SystemVolume.get() ?? 0
        var muted = SystemVolume.isMuted()
        if code == 7 {
            muted.toggle()
            SystemVolume.setMuted(muted)
        } else {
            if muted { muted = false; SystemVolume.setMuted(false) }
            v = code == 0 ? v + step : v - step
            v = (v / step).rounded() * step
            v = min(1, max(0, v))
            SystemVolume.set(v)
        }
        HUDModel.shared.show(HUDEvent(kind: .volume, value: v, muted: muted))
    }

    private func brightness(up: Bool, step: Float) {
        var v = DisplayBrightness.get() ?? 0.5
        v = up ? v + step : v - step
        v = min(1, max(0, (v / step).rounded() * step))
        DisplayBrightness.set(v)
        HUDModel.shared.show(HUDEvent(kind: .brightness, value: v))
    }

    private func keyboard(_ code: Int, step: Float) {
        var v = KeyboardBacklight.get() ?? 0
        switch code {
        case 21: v += step
        case 22: v -= step
        default: v = v > 0 ? 0 : 0.5
        }
        v = min(1, max(0, v))
        KeyboardBacklight.set(v)
        HUDModel.shared.show(HUDEvent(kind: .keyboard, value: v))
    }
}
