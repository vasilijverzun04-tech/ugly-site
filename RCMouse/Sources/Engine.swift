import Cocoa
import Combine
import QuartzCore
import ApplicationServices

/// Живые значения для интерфейса (обновляются ~20 раз в секунду, отдельно от настроек).
final class LiveState: ObservableObject {
    @Published var values: [String: Double] = [:]
    @Published var raws: [String: Int] = [:]
    @Published var zones: [String: Zone] = [:]
    @Published var recent: Set<String> = []
    @Published var lastKey: String?
    @Published var calRanges: [String: ClosedRange<Int>] = [:]
}

enum AxisRole: String {
    case x, y, scrollV, scrollH
}

final class Engine: ObservableObject {
    static let shared = Engine()

    @Published var config: AppConfig {
        didSet {
            if config != oldValue { scheduleSave() }
            if oldValue.enabled && !config.enabled { releaseAll() }
            if !oldValue.enabled && config.enabled { resumeContinuous() }
        }
    }
    @Published private(set) var controls: [ControlInfo] = []
    @Published private(set) var deviceNames: [String] = []
    @Published private(set) var trusted = false
    @Published private(set) var calibrating = false
    @Published private(set) var learningRole: AxisRole?
    @Published private(set) var findingControl = false
    @Published var foundKey: String?
    let live = LiveState()

    private let hid = HIDInput()
    private var infos: [String: ControlInfo] = [:]
    private var raw: [String: Int] = [:]
    private var autoRange: [String: (Int, Int)] = [:]
    private var calObs: [String: (Int, Int)] = [:]
    private var zones: [String: Zone] = [:]
    private var started: [String: BindAction] = [:]
    private var repeatTimers: [String: Timer] = [:]
    private var heldScroll: [String: ActionType] = [:]
    private var mouseHeld: [UInt32: Int] = [:]
    private var precisionCount = 0
    private var turboCount = 0
    private var fracX = 0.0, fracY = 0.0, scrollFracX = 0.0, scrollFracY = 0.0
    private var lastTick = CACurrentMediaTime()
    private var lastLive = 0.0
    private var lastAbs: CGPoint?
    private var dirty = true
    private var recentAt: [String: Double] = [:]
    private var markNorm: [String: Double] = [:]
    private var pendingLastKey: String?
    private var saveWork: DispatchWorkItem?
    private var timers: [Timer] = []
    private var activity: NSObjectProtocol?
    private var learnBase: [String: Double] = [:]
    private var revealed = Set<String>()
    private var firstRaw: [String: Int] = [:]
    private var eventLog: [String] = []
    private var learnTimer: Timer?
    private var pendingLong: [String: Timer] = [:]

    private init() {
        var c = Storage.load()
        // Версия 3: у каждой кнопки два действия — «короткое нажатие» и «удержание».
        // Старые назначения с режимом «удерживать/повторять» переезжают в «удержание».
        if c.version < 3 {
            for (k, a) in c.bindings where !k.hasSuffix(Engine.longSuffix) && a.mode != .tap && a.type.supportsMode {
                if c.bindings[k + Engine.longSuffix] == nil { c.bindings[k + Engine.longSuffix] = a }
                c.bindings[k] = nil
            }
            c.version = 3
        }
        config = c
    }

    // MARK: - Запуск

    func start() {
        // Не даём macOS «усыпить» приложение в фоне (App Nap) — иначе курсор будет дёргаться
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Управление мышью с пульта")

        hid.onDeviceAdded = { [weak self] name, list, initial in self?.deviceAdded(name, list, initial) }
        hid.onDeviceRemoved = { [weak self] name, keys in self?.deviceRemoved(name, keys) }
        hid.onValue = { [weak self] k, v in self?.value(k, v) }
        hid.start()

        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        let t2 = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.checkTrust(prompt: false) }
        RunLoop.main.add(t2, forMode: .common)
        timers = [t, t2]

        checkTrust(prompt: true)
    }

    func shutdown() {
        releaseAll()
        saveWork?.cancel()
        Storage.save(config)
    }

    func checkTrust(prompt: Bool) {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let ok = AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
        if ok != trusted { trusted = ok }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func revealConfig() {
        Storage.save(config)
        NSWorkspace.shared.activateFileViewerSelecting([Storage.url])
    }

    // MARK: - Устройства

    private func deviceAdded(_ name: String, _ list: [ControlInfo], _ initial: [String: Int]) {
        deviceNames.append(name)
        for info in list {
            infos[info.key] = info
            if let v = initial[info.key] {
                raw[info.key] = v
                if info.kind == .axis { autoRange[info.key] = (v, v) }
                // начальное положение запоминаем молча, без срабатывания действий
                zones[info.key] = zoneFor(info, current: nil)
            }
        }
        rebuildControls()
        autoAssign()
        dirty = true
    }

    private func deviceRemoved(_ name: String, _ keys: [String]) {
        for k in keys {
            if let info = infos[k] {
                for z in info.zones { exitZone(k, z, fireShort: false) }
            }
            infos[k] = nil
            raw[k] = nil
            zones[k] = nil
        }
        if let i = deviceNames.firstIndex(of: name) { deviceNames.remove(at: i) }
        rebuildControls()
        dirty = true
    }

    private func rebuildControls() {
        controls = infos.values.filter { !$0.hidden || revealed.contains($0.key) }.sorted {
            ($0.kind.order, $0.usagePage, $0.usage, $0.cookie) < ($1.kind.order, $1.usagePage, $1.usage, $1.cookie)
        }
    }

    /// При первом подключении назначаем первые две оси на курсор (потом можно поменять)
    private func autoAssign() {
        guard !config.mouse.autoAssigned, config.mouse.xAxis == nil, config.mouse.yAxis == nil else { return }
        let axes = controls.filter { $0.kind == .axis }
        guard axes.count >= 2 else { return }
        config.mouse.xAxis = axes[0].key
        config.mouse.yAxis = axes[1].key
        config.mouse.autoAssigned = true
    }

    // MARK: - Обработка входов

    static let longSuffix = "|long"
    func bindKey(_ k: String, _ z: Zone) -> String { "\(k)|\(z.rawValue)" }
    func bindKey(_ k: String, _ z: Zone, long: Bool) -> String { bindKey(k, z) + (long ? Engine.longSuffix : "") }

    private func bound(_ bk: String) -> BindAction? {
        guard let a = config.bindings[bk], a.type != .nothing else { return nil }
        return a
    }

    /// Кнопка/положение стало активным
    private func enterZone(_ k: String, _ z: Zone) {
        let sk = bindKey(k, z), lk = bindKey(k, z, long: true)
        let hasShort = bound(sk) != nil, hasLong = bound(lk) != nil
        if hasShort && hasLong {
            // Ждём: отпустят быстро — короткое действие, держат дольше — удержание
            pendingLong[sk]?.invalidate()
            let t = Timer(timeInterval: max(0.1, config.mouse.longPressTime), repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.pendingLong[sk] = nil
                self.begin(lk, slot: .long)
            }
            RunLoop.main.add(t, forMode: .common)
            pendingLong[sk] = t
        } else if hasLong {
            begin(lk, slot: .long)
        } else if hasShort {
            begin(sk, slot: .short)
        }
    }

    /// Кнопку отпустили / тумблер ушёл из положения
    private func exitZone(_ k: String, _ z: Zone, fireShort: Bool = true) {
        let sk = bindKey(k, z), lk = bindKey(k, z, long: true)
        if let t = pendingLong.removeValue(forKey: sk) {
            t.invalidate()
            if fireShort { begin(sk, slot: .short) }   // отпустили до порога — это короткое нажатие
        }
        end(sk)
        end(lk)
    }

    private func value(_ k: String, _ v: Int) {
        guard let info = infos[k] else { return }
        if info.hidden && !revealed.contains(k) {
            if let r0 = firstRaw[k] ?? raw[k], r0 != v {
                revealed.insert(k)
                rebuildControls()
                log("Обнаружен дополнительный вход \(info.defaultName)")
            } else if firstRaw[k] == nil {
                firstRaw[k] = v
            }
        }
        raw[k] = v
        if info.kind == .axis {
            autoRange[k] = autoRange[k].map { (min($0.0, v), max($0.1, v)) } ?? (v, v)
            if calibrating {
                calObs[k] = calObs[k].map { (min($0.0, v), max($0.1, v)) } ?? (v, v)
            }
        }

        let n = normalized(k)
        if let m = markNorm[k], abs(n - m) < 0.04 {
            // мелкий шум стика — не считаем «активностью»
        } else {
            markNorm[k] = n
            recentAt[k] = CACurrentMediaTime()
            pendingLastKey = k
        }
        dirty = true

        let old = zones[k]
        let new = zoneFor(info, current: old)
        let consumed = checkLearning(k, info, n, new)
        guard new != old else { return }
        zones[k] = new
        log("\(label(info)): \(old?.title ?? "—") → \(new?.title ?? "отпущена")  [сырое \(v), норм. \(String(format: "%.2f", n))]")
        if let o = old { exitZone(k, o) }
        if let z = new, !consumed { enterZone(k, z) }
    }

    private func zoneFor(_ info: ControlInfo, current: Zone?) -> Zone? {
        guard let v = raw[info.key] else { return nil }
        switch info.kind {
        case .button:
            return v != 0 ? .pressed : nil
        case .hat:
            let span = info.logicalMax - info.logicalMin
            let i = v - info.logicalMin
            if span == 3 { return (0...3).contains(i) ? Zone.hat4[i] : nil }
            return (0...7).contains(i) && i <= span ? Zone.hat8[i] : nil
        case .axis:
            let n = normalized(info.key)
            let t = config.mouse.zoneThreshold
            let h = 0.05
            switch current {
            case .some(.low): if n < -t + h { return .low }
            case .some(.high): if n > t - h { return .high }
            case .some(.mid): if abs(n) < t + h { return .mid }
            default: break
            }
            return n <= -t ? .low : (n >= t ? .high : .mid)
        }
    }

    func range(for info: ControlInfo) -> (Double, Double, Double) {
        if let cal = config.calibration[info.key], cal.max - cal.min > 1 {
            return (cal.min, cal.max, cal.center)
        }
        var mn = Double(info.logicalMin), mx = Double(info.logicalMax)
        if mx - mn < 2, let r = autoRange[info.key] {
            mn = Double(r.0); mx = Double(r.1)
        }
        return (mn, mx, (mn + mx) / 2)
    }

    /// Значение от −1 до 1 (для кнопок 0/1)
    func normalized(_ k: String) -> Double {
        guard let info = infos[k], let v = raw[k] else { return 0 }
        switch info.kind {
        case .button: return v != 0 ? 1 : 0
        case .hat: return Double(v)
        case .axis:
            let (mn, mx, c) = range(for: info)
            let d = Double(v)
            if d >= c { return mx - c > 0.5 ? min(1, (d - c) / (mx - c)) : 0 }
            return c - mn > 0.5 ? max(-1, (d - c) / (c - mn)) : 0
        }
    }

    // MARK: - Действия

    enum Slot { case short, long }

    private func begin(_ bk: String, slot: Slot) {
        guard var a = bound(bk) else { return }
        if !config.enabled && !a.type.worksWhenDisabled { return }
        // Короткое нажатие — всегда один раз; удержание — держать (или повторять) до отпускания
        switch slot {
        case .short: a.mode = .tap
        case .long: if a.mode != .repeatWhile { a.mode = .hold }
        }
        started[bk] = a

        switch a.type {
        case .nothing:
            break
        case .leftButton, .rightButton, .middleButton:
            let b = mouseButton(a.type)
            switch a.mode {
            case .tap: Output.click(b)
            case .hold: press(b)
            case .repeatWhile:
                Output.click(b)
                startRepeat(bk) { Output.click(b) }
            }
        case .doubleClick:
            Output.doubleClick()
            if a.mode == .repeatWhile { startRepeat(bk) { Output.doubleClick() } }
        case .key:
            switch a.mode {
            case .tap: Output.keyTap(a)
            case .hold:
                Output.keyCombo(a, down: true)
                if a.keyCode >= 0 { startRepeat(bk) { Output.keyAutorepeat(a) } }
            case .repeatWhile:
                Output.keyTap(a)
                startRepeat(bk) { Output.keyTap(a) }
            }
        case .scrollUp, .scrollDown, .scrollLeft, .scrollRight:
            if a.mode == .tap { Output.scrollStep(a.type) } else { heldScroll[bk] = a.type }
        case .media:
            Output.media(a.media.rawValue)
            if a.mode != .tap { startRepeat(bk) { Output.media(a.media.rawValue) } }
        case .precision:
            precisionCount += 1
        case .turbo:
            turboCount += 1
        case .toggleEnabled:
            config.enabled.toggle()
        case .enable:
            config.enabled = true
        case .disable:
            config.enabled = false
        case .centerCursor:
            let b = CGDisplayBounds(CGMainDisplayID())
            Output.move(to: CGPoint(x: b.midX, y: b.midY), dx: 0, dy: 0, drag: dragButton)
        case .shell:
            Output.shell(a.command)
        }
    }

    private func end(_ bk: String) {
        guard let a = started.removeValue(forKey: bk) else { return }
        repeatTimers.removeValue(forKey: bk)?.invalidate()
        heldScroll.removeValue(forKey: bk)
        switch a.type {
        case .leftButton, .rightButton, .middleButton:
            if a.mode == .hold { release(mouseButton(a.type)) }
        case .key:
            if a.mode == .hold { Output.keyCombo(a, down: false) }
        case .precision:
            precisionCount = max(0, precisionCount - 1)
        case .turbo:
            turboCount = max(0, turboCount - 1)
        default:
            break
        }
    }

    func releaseAll() {
        for t in pendingLong.values { t.invalidate() }
        pendingLong = [:]
        for bk in Array(started.keys) { end(bk) }
    }

    /// После включения — вернуть «удерживаемые» действия тех тумблеров, что уже стоят в нужном положении
    private func resumeContinuous() {
        for (k, z) in zones {
            let bk = bindKey(k, z, long: true)
            guard started[bk] == nil, bound(bk) != nil else { continue }
            begin(bk, slot: .long)
        }
    }

    private func mouseButton(_ t: ActionType) -> CGMouseButton {
        switch t {
        case .rightButton: return .right
        case .middleButton: return .center
        default: return .left
        }
    }

    private func press(_ b: CGMouseButton) {
        let n = (mouseHeld[b.rawValue] ?? 0) + 1
        mouseHeld[b.rawValue] = n
        if n == 1 { Output.button(b, down: true) }
    }

    private func release(_ b: CGMouseButton) {
        let n = (mouseHeld[b.rawValue] ?? 0) - 1
        mouseHeld[b.rawValue] = max(0, n)
        if n == 0 { Output.button(b, down: false) }
    }

    private var dragButton: CGMouseButton? {
        if (mouseHeld[CGMouseButton.left.rawValue] ?? 0) > 0 { return .left }
        if (mouseHeld[CGMouseButton.right.rawValue] ?? 0) > 0 { return .right }
        if (mouseHeld[CGMouseButton.center.rawValue] ?? 0) > 0 { return .center }
        return nil
    }

    private func startRepeat(_ bk: String, _ f: @escaping () -> Void) {
        repeatTimers[bk]?.invalidate()
        let m = config.mouse
        let t = Timer(fire: Date().addingTimeInterval(m.repeatDelay), interval: max(0.02, m.repeatInterval),
                      repeats: true) { _ in f() }
        RunLoop.main.add(t, forMode: .common)
        repeatTimers[bk] = t
    }

    // MARK: - Движение курсора (120 Гц)

    private func shape(_ v: Double) -> Double {
        let dz = config.mouse.deadzone
        let a = abs(v)
        if a <= dz { return 0 }
        let n = min(1, (a - dz) / max(0.0001, 1 - dz))
        return (v < 0 ? -1 : 1) * pow(n, config.mouse.curve)
    }

    private func axis(_ key: String?, _ invert: Bool) -> Double {
        guard let k = key, infos[k] != nil else { return 0 }
        let n = normalized(k)
        return invert ? -n : n
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastTick, 0), 0.05)
        lastTick = now
        if now - lastLive > 1.0 / 20.0 {
            lastLive = now
            publishLive(now)
        }
        guard config.enabled, !infos.isEmpty else { return }

        let m = config.mouse
        var factor = 1.0
        if precisionCount > 0 { factor *= m.precisionFactor }
        if turboCount > 0 { factor *= m.turboFactor }

        let x = axis(m.xAxis, m.invertX)
        let y = axis(m.yAxis, m.invertY)

        switch m.mode {
        case .velocity:
            fracX += shape(x) * m.speed * factor * dt
            fracY += shape(y) * m.speed * factor * dt
            let dx = fracX.rounded(.towardZero), dy = fracY.rounded(.towardZero)
            if dx != 0 || dy != 0 {
                fracX -= dx
                fracY -= dy
                let p = Output.cursor
                let np = Output.clampToScreens(CGPoint(x: p.x + CGFloat(dx), y: p.y + CGFloat(dy)))
                Output.move(to: np, dx: CGFloat(dx), dy: CGFloat(dy), drag: dragButton)
            }
        case .absolute:
            if m.xAxis != nil || m.yAxis != nil {
                let b = CGDisplayBounds(CGMainDisplayID())
                let target = CGPoint(x: b.minX + CGFloat((x + 1) / 2) * (b.width - 1),
                                     y: b.minY + CGFloat((y + 1) / 2) * (b.height - 1))
                let moved: Bool
                if let la = lastAbs { moved = hypot(target.x - la.x, target.y - la.y) > 2 } else { moved = true }
                if moved {
                    let p = Output.cursor
                    lastAbs = target
                    Output.move(to: target, dx: target.x - p.x, dy: target.y - p.y, drag: dragButton)
                }
            }
        }

        // Прокрутка: оси + удерживаемые действия прокрутки
        var sv = shape(axis(m.scrollV, m.invertScrollV)) * m.scrollSpeed * factor
        var sh = shape(axis(m.scrollH, m.invertScrollH)) * m.scrollSpeed * factor
        for t in heldScroll.values {
            switch t {
            case .scrollUp: sv -= m.scrollSpeed * factor
            case .scrollDown: sv += m.scrollSpeed * factor
            case .scrollLeft: sh -= m.scrollSpeed * factor
            case .scrollRight: sh += m.scrollSpeed * factor
            default: break
            }
        }
        scrollFracY += sv * dt
        scrollFracX += sh * dt
        let iy = scrollFracY.rounded(.towardZero), ix = scrollFracX.rounded(.towardZero)
        if iy != 0 || ix != 0 {
            scrollFracY -= iy
            scrollFracX -= ix
            Output.scroll(dy: Int32(-iy), dx: Int32(-ix), pixels: true)
        }
    }

    private func publishLive(_ now: Double) {
        let recent = Set(recentAt.filter { now - $0.value < 0.6 }.keys)
        if !dirty && recent == live.recent { return }
        dirty = false
        var vals: [String: Double] = [:]
        for k in infos.keys { vals[k] = normalized(k) }
        live.values = vals
        live.raws = raw
        live.zones = zones
        if recent != live.recent { live.recent = recent }
        if let lk = pendingLastKey, lk != live.lastKey { live.lastKey = lk }
        if calibrating {
            var r: [String: ClosedRange<Int>] = [:]
            for (k, v) in calObs { r[k] = v.0...v.1 }
            live.calRanges = r
        }
    }

    // MARK: - Автоопределение («подвигайте стиком», «нажмите кнопку»)

    func learnAxis(_ role: AxisRole) {
        snapshotBase()
        findingControl = false
        learningRole = role
        restartLearnTimer()
    }

    func startFind() {
        snapshotBase()
        learningRole = nil
        foundKey = nil
        findingControl = true
        restartLearnTimer()
    }

    func stopLearning() {
        learningRole = nil
        findingControl = false
        learnTimer?.invalidate()
    }

    private func snapshotBase() {
        learnBase = [:]
        for k in infos.keys { learnBase[k] = normalized(k) }
    }

    private func restartLearnTimer() {
        learnTimer?.invalidate()
        let t = Timer(timeInterval: 12, repeats: false) { [weak self] _ in self?.stopLearning() }
        RunLoop.main.add(t, forMode: .common)
        learnTimer = t
    }

    /// true — событие «съедено» автоопределением (действие при этом не выполняется)
    private func checkLearning(_ k: String, _ info: ControlInfo, _ n: Double, _ zone: Zone?) -> Bool {
        if let role = learningRole {
            guard info.kind == .axis, abs(n - (learnBase[k] ?? 0)) > 0.5 else { return false }
            switch role {
            case .x: config.mouse.xAxis = k
            case .y: config.mouse.yAxis = k
            case .scrollV: config.mouse.scrollV = k
            case .scrollH: config.mouse.scrollH = k
            }
            stopLearning()
            return true
        }
        if findingControl {
            let hit: Bool
            switch info.kind {
            case .axis: hit = abs(n - (learnBase[k] ?? 0)) > 0.5
            case .button: hit = n > 0.5
            case .hat: hit = zone != nil
            }
            guard hit else { return false }
            foundKey = k
            stopLearning()
            return true
        }
        return false
    }

    // MARK: - Калибровка

    func startCalibration() {
        calObs = [:]
        for (k, info) in infos where info.kind == .axis {
            if let v = raw[k] { calObs[k] = (v, v) }
        }
        live.calRanges = [:]
        calibrating = true
    }

    func cancelCalibration() {
        calibrating = false
        calObs = [:]
        live.calRanges = [:]
    }

    func finishCalibration() {
        var cal = config.calibration
        for (k, r) in calObs {
            guard let info = infos[k] else { continue }
            let span = r.1 - r.0
            let lspan = max(1, info.logicalMax - info.logicalMin)
            guard span >= max(4, lspan / 50) else { continue }   // ось не двигали
            var center = Double(r.0 + r.1) / 2
            // если стик сейчас примерно в центре — берём его реальный центр (с учётом триммеров)
            if let v = raw[k], abs(Double(v) - center) < Double(span) * 0.15 { center = Double(v) }
            cal[k] = AxisCal(min: Double(r.0), max: Double(r.1), center: center)
        }
        calibrating = false
        calObs = [:]
        live.calRanges = [:]
        config.calibration = cal
        dirty = true
    }

    func captureCenters() {
        var cal = config.calibration
        for (k, info) in infos where info.kind == .axis {
            guard let v = raw[k] else { continue }
            let (mn, mx, _) = range(for: info)
            let d = Double(v)
            if abs(d - (mn + mx) / 2) < (mx - mn) * 0.2 {
                cal[k] = AxisCal(min: mn, max: mx, center: d)
            }
        }
        config.calibration = cal
        dirty = true
    }

    func resetCalibration() {
        config.calibration = [:]
        dirty = true
    }

    // MARK: - Диагностика

    private func log(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        eventLog.append("\(f.string(from: Date()))  \(s)")
        if eventLog.count > 60 { eventLog.removeFirst(eventLog.count - 60) }
    }

    func diagnosticsReport() -> String {
        var out = "RC Mouse — отчёт\n"
        out += "Устройства: \(deviceNames.isEmpty ? "нет" : deviceNames.joined(separator: ", "))\n"
        out += "Универсальный доступ: \(trusted ? "да" : "НЕТ"), управление: \(config.enabled ? "вкл" : "выкл")\n"
        let m = config.mouse
        func ax(_ k: String?) -> String {
            guard let k = k else { return "не назначена" }
            guard infos[k] != nil else { return "\(k) (нет такого входа сейчас!)" }
            return "\(label(forKey: k)) = \(String(format: "%.2f", normalized(k)))"
        }
        out += "Мышь: режим \(m.mode.rawValue), X: \(ax(m.xAxis)), Y: \(ax(m.yAxis)), скорость \(Int(m.speed)), мёртвая зона \(m.deadzone)\n"
        out += "Прокрутка: ↕ \(ax(m.scrollV)), ↔ \(ax(m.scrollH))\n\n"
        out += "Входы:\n"
        let all = infos.values.sorted { ($0.kind.order, $0.cookie) < ($1.kind.order, $1.cookie) }
        for i in all {
            let r = raw[i.key].map { String($0) } ?? "—"
            let z = zones[i.key]?.title ?? "—"
            out += String(format: "  %@ | %@ | page 0x%lX usage 0x%lX cookie %ld | %ld…%ld | сырое %@ | норм %.2f | %@%@\n",
                          label(i), i.kind.title, i.usagePage, i.usage, i.cookie, i.logicalMin, i.logicalMax,
                          r, normalized(i.key), z, i.hidden ? " | доп." : "")
            for zone in i.zones {
                if let a = config.bindings[bindKey(i.key, zone)] {
                    out += "      \(zone.title) — коротко: \(a.shortTitle)\n"
                }
                if let a = config.bindings[bindKey(i.key, zone, long: true)] {
                    out += "      \(zone.title) — удержание: \(a.shortTitle) (\(a.mode.title))\n"
                }
            }
        }
        out += "\nПоследние события:\n" + (eventLog.isEmpty ? "  (нет)\n" : eventLog.map { "  " + $0 }.joined(separator: "\n") + "\n")
        return out
    }

    private var testStep = 0
    private var testStart = CGPoint.zero
    private var testTimer: Timer?

    /// Рисует курсором кружок — проверка, что macOS разрешает программе двигать мышь
    func testCursor() {
        testTimer?.invalidate()
        testStep = 0
        testStart = Output.cursor
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.testTick() }
        RunLoop.main.add(t, forMode: .common)
        testTimer = t
    }

    private func testTick() {
        testStep += 1
        let a = Double(testStep) / 60.0 * 2 * Double.pi
        let p = CGPoint(x: testStart.x + CGFloat(cos(a) * 80) - 80, y: testStart.y + CGFloat(sin(a) * 80))
        Output.move(to: p, dx: 0, dy: 0, drag: nil)
        if testStep >= 60 {
            testTimer?.invalidate()
            testTimer = nil
            log("Тест курсора выполнен (курсор \(Output.cursor == testStart ? "НЕ сдвинулся" : "двигается"))")
        }
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticsReport(), forType: .string)
    }

    // MARK: - Подписи

    func label(_ info: ControlInfo) -> String {
        if let l = config.labels[info.key], !l.isEmpty { return l }
        return info.defaultName
    }

    func label(forKey k: String) -> String {
        if let info = infos[k] { return label(info) }
        return config.labels[k] ?? k
    }

    func summary(_ info: ControlInfo) -> String {
        var parts: [String] = []
        let m = config.mouse
        if m.xAxis == info.key { parts.append("курсор X") }
        if m.yAxis == info.key { parts.append("курсор Y") }
        if m.scrollV == info.key { parts.append("прокрутка ↕") }
        if m.scrollH == info.key { parts.append("прокрутка ↔") }
        for z in info.zones {
            let p = z.short.isEmpty ? "" : "\(z.short) "
            if let a = bound(bindKey(info.key, z)) { parts.append("\(p)👆 \(a.shortTitle)") }
            if let a = bound(bindKey(info.key, z, long: true)) { parts.append("\(p)✊ \(a.shortTitle)") }
        }
        return parts.isEmpty ? "не назначено" : parts.joined(separator: " · ")
    }

    // MARK: - Сохранение

    private func scheduleSave() {
        saveWork?.cancel()
        let c = config
        let w = DispatchWorkItem { Storage.save(c) }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }
}
