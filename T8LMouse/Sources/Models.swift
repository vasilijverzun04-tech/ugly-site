import Foundation

// MARK: - Входы пульта

enum ControlKind: String, Codable {
    case axis, button, hat

    var title: String {
        switch self {
        case .axis: return "ось / тумблер"
        case .button: return "кнопка"
        case .hat: return "крестовина"
        }
    }

    var order: Int {
        switch self {
        case .axis: return 0
        case .hat: return 1
        case .button: return 2
        }
    }
}

/// Положение входа. Каждое положение — отдельная «кнопка», на которую можно назначить действие.
enum Zone: String, Codable, CaseIterable {
    case pressed, low, mid, high
    case up, upRight, right, downRight, down, downLeft, left, upLeft

    static let hat8: [Zone] = [.up, .upRight, .right, .downRight, .down, .downLeft, .left, .upLeft]
    static let hat4: [Zone] = [.up, .right, .down, .left]

    var title: String {
        switch self {
        case .pressed: return "Нажата"
        case .low: return "Положение «минимум» (−)"
        case .mid: return "Положение «середина»"
        case .high: return "Положение «максимум» (+)"
        case .up: return "Вверх"
        case .upRight: return "Вверх-вправо"
        case .right: return "Вправо"
        case .downRight: return "Вниз-вправо"
        case .down: return "Вниз"
        case .downLeft: return "Вниз-влево"
        case .left: return "Влево"
        case .upLeft: return "Вверх-влево"
        }
    }

    var short: String {
        switch self {
        case .pressed: return ""
        case .low: return "−"
        case .mid: return "0"
        case .high: return "+"
        case .up: return "↑"
        case .upRight: return "↗"
        case .right: return "→"
        case .downRight: return "↘"
        case .down: return "↓"
        case .downLeft: return "↙"
        case .left: return "←"
        case .upLeft: return "↖"
        }
    }
}

struct ControlInfo: Identifiable, Hashable {
    let key: String
    let kind: ControlKind
    let usagePage: Int
    let usage: Int
    let cookie: Int
    let logicalMin: Int
    let logicalMax: Int
    var defaultName: String
    let device: String
    /// Нестандартный вход (без usage / vendor page) — показывается, когда впервые изменится
    var hidden: Bool = false

    var id: String { key }

    var zones: [Zone] {
        switch kind {
        case .button: return [.pressed]
        case .axis: return [.low, .mid, .high]
        case .hat: return (logicalMax - logicalMin == 3) ? Zone.hat4 : Zone.hat8
        }
    }
}

// MARK: - Действия

enum PressMode: String, Codable, CaseIterable, Identifiable {
    case tap, hold, repeatWhile
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tap: return "Один раз при включении"
        case .hold: return "Удерживать, пока активно"
        case .repeatWhile: return "Повторять, пока активно"
        }
    }
}

enum ActionType: String, Codable, CaseIterable, Identifiable {
    case nothing = "none"
    case leftButton, rightButton, middleButton, doubleClick
    case key
    case scrollUp, scrollDown, scrollLeft, scrollRight
    case media
    case precision, turbo
    case toggleEnabled, enable, disable
    case centerCursor
    case shell

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nothing: return "— ничего —"
        case .leftButton: return "Левая кнопка мыши"
        case .rightButton: return "Правая кнопка мыши"
        case .middleButton: return "Средняя кнопка мыши"
        case .doubleClick: return "Двойной клик"
        case .key: return "Клавиша / сочетание клавиш"
        case .scrollUp: return "Прокрутка вверх"
        case .scrollDown: return "Прокрутка вниз"
        case .scrollLeft: return "Прокрутка влево"
        case .scrollRight: return "Прокрутка вправо"
        case .media: return "Медиа (громкость, плеер, яркость)"
        case .precision: return "Точный режим (медленный курсор)"
        case .turbo: return "Турбо (быстрый курсор)"
        case .toggleEnabled: return "Вкл/выкл управление пультом"
        case .enable: return "Включить управление"
        case .disable: return "Выключить управление"
        case .centerCursor: return "Курсор в центр экрана"
        case .shell: return "Команда / открыть программу"
        }
    }

    var supportsMode: Bool {
        switch self {
        case .leftButton, .rightButton, .middleButton, .doubleClick, .key,
             .scrollUp, .scrollDown, .scrollLeft, .scrollRight, .media:
            return true
        default:
            return false
        }
    }

    /// Эти действия работают, даже когда управление выключено (чтобы можно было включить обратно).
    var worksWhenDisabled: Bool { self == .toggleEnabled || self == .enable }

    var isMouseButton: Bool { self == .leftButton || self == .rightButton || self == .middleButton }
}

enum MediaKey: Int, Codable, CaseIterable, Identifiable {
    case volumeUp = 0, volumeDown = 1, brightnessUp = 2, brightnessDown = 3
    case mute = 7, playPause = 16, next = 17, previous = 18
    case keyboardLightUp = 21, keyboardLightDown = 22

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .volumeUp: return "Громкость +"
        case .volumeDown: return "Громкость −"
        case .mute: return "Без звука"
        case .playPause: return "Play / Pause"
        case .next: return "Следующий трек"
        case .previous: return "Предыдущий трек"
        case .brightnessUp: return "Яркость +"
        case .brightnessDown: return "Яркость −"
        case .keyboardLightUp: return "Подсветка клавиатуры +"
        case .keyboardLightDown: return "Подсветка клавиатуры −"
        }
    }
}

struct BindAction: Codable, Equatable {
    var type: ActionType = .nothing
    var mode: PressMode = .tap
    var keyCode: Int = -1
    var cmd = false
    var shift = false
    var option = false
    var control = false
    var media: MediaKey = .playPause
    var command: String = ""

    var shortTitle: String {
        switch type {
        case .key:
            var s = ""
            if control { s += "⌃" }
            if option { s += "⌥" }
            if shift { s += "⇧" }
            if cmd { s += "⌘" }
            if keyCode >= 0 { s += KeyCatalog.name(keyCode) }
            return s.isEmpty ? "клавиша" : s
        case .media: return media.title
        case .shell: return command.isEmpty ? "команда" : "$ " + command
        default: return type.title
        }
    }
}

// MARK: - Настройки мыши

enum MouseMode: String, Codable, CaseIterable, Identifiable {
    case velocity, absolute
    var id: String { rawValue }
    var title: String {
        switch self {
        case .velocity: return "Как джойстик — отклонение стика задаёт скорость курсора"
        case .absolute: return "Абсолютный — положение стика = точка на экране"
        }
    }
}

struct MouseSettings: Codable, Equatable {
    var mode: MouseMode = .velocity
    var xAxis: String? = nil
    var yAxis: String? = nil
    var scrollV: String? = nil
    var scrollH: String? = nil
    var invertX = false
    var invertY = false
    var invertScrollV = false
    var invertScrollH = false
    var speed: Double = 1400
    var scrollSpeed: Double = 900
    var deadzone: Double = 0.05
    var curve: Double = 1.8
    var precisionFactor: Double = 0.25
    var turboFactor: Double = 3
    var zoneThreshold: Double = 0.35
    var repeatInterval: Double = 0.1
    var repeatDelay: Double = 0.35
    var autoAssigned = false
}

struct AxisCal: Codable, Equatable {
    var min: Double
    var max: Double
    var center: Double
}

struct AppConfig: Codable, Equatable {
    var enabled = true
    var mouse = MouseSettings()
    var bindings: [String: BindAction] = [:]
    var labels: [String: String] = [:]
    var calibration: [String: AxisCal] = [:]
}

// MARK: - Устойчивое чтение JSON (новые/отсутствующие поля не ломают настройки)

extension KeyedDecodingContainer {
    func get<T: Decodable>(_ key: Key, _ def: T) -> T {
        if let v = try? decodeIfPresent(T.self, forKey: key) { return v }
        return def
    }
}

extension BindAction {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BindAction()
        type = c.get(.type, d.type)
        mode = c.get(.mode, d.mode)
        keyCode = c.get(.keyCode, d.keyCode)
        cmd = c.get(.cmd, d.cmd)
        shift = c.get(.shift, d.shift)
        option = c.get(.option, d.option)
        control = c.get(.control, d.control)
        media = c.get(.media, d.media)
        command = c.get(.command, d.command)
    }
}

extension MouseSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MouseSettings()
        mode = c.get(.mode, d.mode)
        xAxis = c.get(.xAxis, d.xAxis)
        yAxis = c.get(.yAxis, d.yAxis)
        scrollV = c.get(.scrollV, d.scrollV)
        scrollH = c.get(.scrollH, d.scrollH)
        invertX = c.get(.invertX, d.invertX)
        invertY = c.get(.invertY, d.invertY)
        invertScrollV = c.get(.invertScrollV, d.invertScrollV)
        invertScrollH = c.get(.invertScrollH, d.invertScrollH)
        speed = c.get(.speed, d.speed)
        scrollSpeed = c.get(.scrollSpeed, d.scrollSpeed)
        deadzone = c.get(.deadzone, d.deadzone)
        curve = c.get(.curve, d.curve)
        precisionFactor = c.get(.precisionFactor, d.precisionFactor)
        turboFactor = c.get(.turboFactor, d.turboFactor)
        zoneThreshold = c.get(.zoneThreshold, d.zoneThreshold)
        repeatInterval = c.get(.repeatInterval, d.repeatInterval)
        repeatDelay = c.get(.repeatDelay, d.repeatDelay)
        autoAssigned = c.get(.autoAssigned, d.autoAssigned)
    }
}

extension AppConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        enabled = c.get(.enabled, d.enabled)
        mouse = c.get(.mouse, d.mouse)
        bindings = c.get(.bindings, d.bindings)
        labels = c.get(.labels, d.labels)
        calibration = c.get(.calibration, d.calibration)
    }
}

// MARK: - Сохранение

enum Storage {
    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("T8LMouse", isDirectory: true).appendingPathComponent("config.json")
    }

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) else { return AppConfig() }
        return cfg
    }

    static func save(_ cfg: AppConfig) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(cfg).write(to: url, options: .atomic)
        } catch {
            NSLog("T8LMouse: не удалось сохранить настройки: \(error)")
        }
    }
}

// MARK: - Клавиши (коды клавиш macOS, расположение как на US-клавиатуре)

struct KeyDef {
    let name: String
    let code: Int
}

enum KeyCatalog {
    static let keys: [KeyDef] = {
        var k: [KeyDef] = [
            KeyDef(name: "— без клавиши (только модификаторы) —", code: -1),
            KeyDef(name: "Пробел", code: 49),
            KeyDef(name: "Return ↩", code: 36),
            KeyDef(name: "Esc", code: 53),
            KeyDef(name: "Tab ⇥", code: 48),
            KeyDef(name: "Delete ⌫", code: 51),
            KeyDef(name: "Forward Delete ⌦", code: 117),
            KeyDef(name: "Стрелка ←", code: 123),
            KeyDef(name: "Стрелка →", code: 124),
            KeyDef(name: "Стрелка ↓", code: 125),
            KeyDef(name: "Стрелка ↑", code: 126),
            KeyDef(name: "Home", code: 115),
            KeyDef(name: "End", code: 119),
            KeyDef(name: "Page Up", code: 116),
            KeyDef(name: "Page Down", code: 121),
        ]
        let letters: [(String, Int)] = [
            ("A", 0), ("B", 11), ("C", 8), ("D", 2), ("E", 14), ("F", 3), ("G", 5), ("H", 4), ("I", 34),
            ("J", 38), ("K", 40), ("L", 37), ("M", 46), ("N", 45), ("O", 31), ("P", 35), ("Q", 12),
            ("R", 15), ("S", 1), ("T", 17), ("U", 32), ("V", 9), ("W", 13), ("X", 7), ("Y", 16), ("Z", 6),
        ]
        let digits: [(String, Int)] = [
            ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23), ("6", 22), ("7", 26), ("8", 28), ("9", 25), ("0", 29),
        ]
        let fkeys: [(String, Int)] = [
            ("F1", 122), ("F2", 120), ("F3", 99), ("F4", 118), ("F5", 96), ("F6", 97), ("F7", 98), ("F8", 100),
            ("F9", 101), ("F10", 109), ("F11", 103), ("F12", 111), ("F13", 105), ("F14", 107), ("F15", 113),
            ("F16", 106), ("F17", 64), ("F18", 79), ("F19", 80),
        ]
        let symbols: [(String, Int)] = [
            ("-", 27), ("=", 24), ("[", 33), ("]", 30), (";", 41), ("'", 39), (",", 43), (".", 47),
            ("/", 44), ("\\", 42), ("`", 50),
        ]
        for (n, c) in letters + digits + fkeys + symbols { k.append(KeyDef(name: n, code: c)) }
        return k
    }()

    static func name(_ code: Int) -> String {
        if let k = keys.first(where: { $0.code == code }) {
            return k.name.replacingOccurrences(of: "Стрелка ", with: "")
        }
        return "#\(code)"
    }
}
