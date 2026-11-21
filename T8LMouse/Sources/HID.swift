import Foundation
import IOKit
import IOKit.hid

/// Читает любой USB/Bluetooth HID-джойстик (RadioMaster T8L в режиме джойстика/симулятора и т.п.).
/// Работает с IOKit напрямую, поэтому видит ВСЕ оси, кнопки и крестовины устройства,
/// а не только те, что понимает GameController.framework.
final class HIDInput {
    private let manager: IOHIDManager
    private var devices: [ObjectIdentifier: (device: IOHIDDevice, name: String, keys: [String])] = [:]

    var onDeviceAdded: ((String, [ControlInfo], [String: Int]) -> Void)?
    var onDeviceRemoved: ((String, [String]) -> Void)?
    var onValue: ((String, Int) -> Void)?

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func start() {
        // Generic Desktop: Joystick (0x04), GamePad (0x05), Multi-axis Controller (0x08)
        let matching: [[String: Any]] = [0x04, 0x05, 0x08].map {
            [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: $0]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            guard let ctx = ctx else { return }
            Unmanaged<HIDInput>.fromOpaque(ctx).takeUnretainedValue().added(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            guard let ctx = ctx else { return }
            Unmanaged<HIDInput>.fromOpaque(ctx).takeUnretainedValue().removed(device)
        }, ctx)
        IOHIDManagerRegisterInputValueCallback(manager, { ctx, _, _, value in
            guard let ctx = ctx else { return }
            Unmanaged<HIDInput>.fromOpaque(ctx).takeUnretainedValue().changed(value)
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let r = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if r != kIOReturnSuccess {
            NSLog("T8LMouse: IOHIDManagerOpen вернул \(r)")
        }
    }

    static func key(_ e: IOHIDElement) -> String {
        "\(IOHIDElementGetUsagePage(e))_\(IOHIDElementGetUsage(e))_\(IOHIDElementGetCookie(e))"
    }

    private func added(_ device: IOHIDDevice) {
        let product = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "Джойстик"
        guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else {
            return
        }

        var infos: [ControlInfo] = []
        var initial: [String: Int] = [:]
        var seen = Set<String>()

        for e in elements {
            // 1 = Input_Misc, 2 = Input_Button, 3 = Input_Axis
            let t = IOHIDElementGetType(e).rawValue
            guard t == 1 || t == 2 || t == 3 else { continue }
            let page = Int(IOHIDElementGetUsagePage(e))
            let usage = Int(IOHIDElementGetUsage(e))
            if page == 0 || page >= 0xFF00 || usage == 0 || usage == 0xFFFF_FFFF { continue }
            if IOHIDElementGetReportSize(e) == 0 { continue }

            let k = HIDInput.key(e)
            if seen.contains(k) { continue }
            seen.insert(k)

            let lmin = IOHIDElementGetLogicalMin(e)
            let lmax = IOHIDElementGetLogicalMax(e)
            let kind: ControlKind
            if page == 0x09 {
                kind = .button
            } else if page == 0x01 && usage == 0x39 {
                kind = .hat
            } else if lmax - lmin == 1 {
                kind = .button
            } else {
                kind = .axis
            }

            infos.append(ControlInfo(
                key: k, kind: kind, usagePage: page, usage: usage,
                cookie: Int(IOHIDElementGetCookie(e)),
                logicalMin: lmin, logicalMax: lmax,
                defaultName: HIDInput.name(page: page, usage: usage),
                device: product))

            // Текущее значение — чтобы знать, в каком положении тумблеры уже стоят
            let ptr = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
            if IOHIDDeviceGetValue(device, e, ptr) == kIOReturnSuccess {
                initial[k] = IOHIDValueGetIntegerValue(ptr.pointee.takeUnretainedValue())
            }
            ptr.deallocate()
        }

        // Одинаковые имена (например, несколько «Slider») — пронумеровать
        var counts: [String: Int] = [:]
        for i in infos { counts[i.defaultName, default: 0] += 1 }
        var idx: [String: Int] = [:]
        for i in infos.indices where counts[infos[i].defaultName, default: 0] > 1 {
            let n = infos[i].defaultName
            idx[n, default: 0] += 1
            infos[i].defaultName = "\(n) #\(idx[n]!)"
        }

        devices[ObjectIdentifier(device)] = (device, product, infos.map { $0.key })
        onDeviceAdded?(product, infos, initial)
    }

    private func removed(_ device: IOHIDDevice) {
        guard let d = devices.removeValue(forKey: ObjectIdentifier(device)) else { return }
        onDeviceRemoved?(d.name, d.keys)
    }

    private func changed(_ value: IOHIDValue) {
        let e = IOHIDValueGetElement(value)
        onValue?(HIDInput.key(e), IOHIDValueGetIntegerValue(value))
    }

    static func name(page: Int, usage: Int) -> String {
        if page == 0x09 { return "Кнопка \(usage)" }
        if page == 0x01 {
            switch usage {
            case 0x30: return "Ось X"
            case 0x31: return "Ось Y"
            case 0x32: return "Ось Z"
            case 0x33: return "Ось Rx"
            case 0x34: return "Ось Ry"
            case 0x35: return "Ось Rz"
            case 0x36: return "Slider"
            case 0x37: return "Dial"
            case 0x38: return "Wheel"
            case 0x39: return "Крестовина"
            default: break
            }
        }
        if page == 0x02 {
            switch usage {
            case 0xB0: return "Элероны (Aileron)"
            case 0xB8: return "Руль высоты (Elevator)"
            case 0xBA: return "Руль направления (Rudder)"
            case 0xBB: return "Газ (Throttle)"
            case 0xC4: return "Accelerator"
            case 0xC5: return "Brake"
            case 0xC8: return "Steering"
            default: break
            }
        }
        return String(format: "Вход 0x%02X:0x%02X", page, usage)
    }
}
