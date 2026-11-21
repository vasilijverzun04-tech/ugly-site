import Cocoa
import CoreGraphics

/// Отправка синтетических событий мыши и клавиатуры (нужен доступ «Универсальный доступ»).
enum Output {
    static let source: CGEventSource? = {
        let s = CGEventSource(stateID: .hidSystemState)
        s?.localEventsSuppressionInterval = 0
        return s
    }()

    static var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    // MARK: Мышь

    static func move(to p: CGPoint, dx: CGFloat, dy: CGFloat, drag: CGMouseButton?) {
        let type: CGEventType
        switch drag {
        case .some(.left): type = .leftMouseDragged
        case .some(.right): type = .rightMouseDragged
        case .some: type = .otherMouseDragged
        case .none: type = .mouseMoved
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                              mouseCursorPosition: p, mouseButton: drag ?? .left) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        e.post(tap: .cghidEventTap)
    }

    static func button(_ b: CGMouseButton, down: Bool, clickState: Int64 = 1) {
        let type: CGEventType
        switch b {
        case .left: type = down ? .leftMouseDown : .leftMouseUp
        case .right: type = down ? .rightMouseDown : .rightMouseUp
        default: type = down ? .otherMouseDown : .otherMouseUp
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                              mouseCursorPosition: cursor, mouseButton: b) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: clickState)
        e.post(tap: .cghidEventTap)
    }

    static func click(_ b: CGMouseButton) {
        button(b, down: true)
        button(b, down: false)
    }

    static func doubleClick() {
        button(.left, down: true, clickState: 1)
        button(.left, down: false, clickState: 1)
        button(.left, down: true, clickState: 2)
        button(.left, down: false, clickState: 2)
    }

    static func scroll(dy: Int32, dx: Int32, pixels: Bool) {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: pixels ? .pixel : .line,
                              wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        e.post(tap: .cghidEventTap)
    }

    static func scrollStep(_ t: ActionType) {
        switch t {
        case .scrollUp: scroll(dy: 3, dx: 0, pixels: false)
        case .scrollDown: scroll(dy: -3, dx: 0, pixels: false)
        case .scrollLeft: scroll(dy: 0, dx: 3, pixels: false)
        case .scrollRight: scroll(dy: 0, dx: -3, pixels: false)
        default: break
        }
    }

    static func displayRects() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        if count == 0 { return [CGDisplayBounds(CGMainDisplayID())] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    /// Не даём курсору уйти за пределы мониторов
    static func clampToScreens(_ p: CGPoint) -> CGPoint {
        let rects = displayRects()
        if rects.contains(where: { $0.contains(p) }) { return p }
        var best = p
        var bestD = CGFloat.greatestFiniteMagnitude
        for r in rects {
            let c = CGPoint(x: min(max(p.x, r.minX), r.maxX - 1), y: min(max(p.y, r.minY), r.maxY - 1))
            let d = hypot(c.x - p.x, c.y - p.y)
            if d < bestD { bestD = d; best = c }
        }
        return best
    }

    // MARK: Клавиатура

    static func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags, autorepeat: Bool = false) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        e.flags = flags
        if autorepeat { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        e.post(tap: .cghidEventTap)
    }

    static func modifiers(_ a: BindAction) -> [(CGKeyCode, CGEventFlags)] {
        var r: [(CGKeyCode, CGEventFlags)] = []
        if a.control { r.append((59, .maskControl)) }
        if a.option { r.append((58, .maskAlternate)) }
        if a.shift { r.append((56, .maskShift)) }
        if a.cmd { r.append((55, .maskCommand)) }
        return r
    }

    static func flags(_ a: BindAction) -> CGEventFlags {
        var f: CGEventFlags = []
        for (_, flag) in modifiers(a) { f.insert(flag) }
        return f
    }

    /// Автоповтор зажатой клавиши — как при удержании клавиши на настоящей клавиатуре
    static func keyAutorepeat(_ a: BindAction) {
        guard a.keyCode >= 0 else { return }
        key(CGKeyCode(a.keyCode), down: true, flags: flags(a), autorepeat: true)
    }

    static func keyCombo(_ a: BindAction, down: Bool) {
        let mods = modifiers(a)
        var f: CGEventFlags = []
        if down {
            for (code, flag) in mods { f.insert(flag); key(code, down: true, flags: f) }
            if a.keyCode >= 0 { key(CGKeyCode(a.keyCode), down: true, flags: f) }
        } else {
            for (_, flag) in mods { f.insert(flag) }
            if a.keyCode >= 0 { key(CGKeyCode(a.keyCode), down: false, flags: f) }
            for (code, flag) in mods.reversed() { f.remove(flag); key(code, down: false, flags: f) }
        }
    }

    static func keyTap(_ a: BindAction) {
        keyCombo(a, down: true)
        keyCombo(a, down: false)
    }

    /// Медиа-клавиши (громкость, плеер, яркость) — как верхний ряд клавиатуры Mac
    static func media(_ k: Int) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = (k << 16) | ((down ? 0xA : 0xB) << 8)
            if let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           subtype: 8, data1: data1, data2: -1) {
                ev.cgEvent?.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: Команды

    static func shell(_ cmd: String) {
        let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", trimmed]
        do { try p.run() } catch { NSLog("RCMouse: не удалось выполнить команду: \(error)") }
    }
}
