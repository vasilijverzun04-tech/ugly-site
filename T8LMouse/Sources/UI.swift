import SwiftUI

// MARK: - Привязки для интерфейса

extension Engine {
    func actionBinding(_ info: ControlInfo, _ zone: Zone) -> Binding<BindAction> {
        let bk = bindKey(info.key, zone)
        return Binding(
            get: { self.config.bindings[bk] ?? BindAction() },
            set: { newValue in
                var v = newValue
                let old = self.config.bindings[bk]
                // Для настоящих кнопок по умолчанию логичнее «удерживать» (как кнопка мыши/клавиатуры)
                if old == nil, info.kind == .button, v.type.isMouseButton || v.type == .key {
                    v.mode = .hold
                }
                self.config.bindings[bk] = (v.type == .nothing) ? nil : v
            })
    }

    func labelBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { self.config.labels[key] ?? "" },
            set: { self.config.labels[key] = $0.isEmpty ? nil : $0 })
    }
}

// MARK: - Главное окно

struct ContentView: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(live: engine.live)
            Divider()
            TabView {
                InputsTab()
                    .tabItem { Text("Кнопки и тумблеры") }
                MouseTab()
                    .tabItem { Text("Мышь") }
                CalibrationTab(live: engine.live)
                    .tabItem { Text("Калибровка") }
                HelpTab()
                    .tabItem { Text("Справка") }
            }
            .padding(8)
        }
        .frame(minWidth: 900, minHeight: 620)
    }
}

struct HeaderView: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var live: LiveState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Toggle(isOn: $engine.config.enabled) {
                    Text("Управление пультом включено").font(.headline)
                }
                .toggleStyle(SwitchToggleStyle())

                Spacer()

                if engine.deviceNames.isEmpty {
                    Text("● Пульт не найден — подключите T8L кабелем USB-C (режим джойстика)")
                        .foregroundColor(.red)
                } else {
                    Text("● Подключено: " + engine.deviceNames.joined(separator: ", "))
                        .foregroundColor(.green)
                }
            }

            if !engine.trusted {
                HStack(spacing: 10) {
                    Text("⚠️ Нет разрешения «Универсальный доступ» — без него программа не может двигать мышь и нажимать клавиши.")
                        .foregroundColor(.orange)
                    Button("Открыть настройки") { engine.openAccessibilitySettings() }
                    Button("Проверить") { engine.checkTrust(prompt: true) }
                }
            }

            HStack {
                Text("Последний сработавший вход:").foregroundColor(.secondary)
                if let k = live.lastKey {
                    Text(engine.label(forKey: k)).bold()
                    if let z = live.zones[k] { Text("→ " + z.title).foregroundColor(.secondary) }
                } else {
                    Text("— пошевелите стиком или переключите тумблер —").foregroundColor(.secondary)
                }
            }
            .font(.callout)
        }
        .padding(12)
    }
}

// MARK: - Вкладка «Кнопки и тумблеры»

struct InputsTab: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        if engine.controls.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Text("Пульт не подключён").font(.title2)
                Text("Подключите RadioMaster T8L к Mac кабелем USB-C (кабель должен передавать данные).\nЕсли пульт спросит режим USB — выберите «Joystick» / «HID» / «Simulator».")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    if engine.findingControl {
                        Button("Отмена") { engine.stopLearning() }
                        Text("Нажмите кнопку или переключите тумблер на пульте…")
                            .foregroundColor(.orange).bold()
                    } else {
                        Button("🔍 Найти кнопку на пульте") { engine.startFind() }
                        Text("Нажмите, затем щёлкните тумблером на пульте — откроются его настройки.")
                            .font(.callout).foregroundColor(.secondary)
                    }
                    Spacer()
                    CopyReportButton()
                }
                .padding(10)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Каждое положение тумблера и каждая кнопка — отдельная «кнопка», на неё можно назначить действие. Строки можно переименовать (например «SA», «Левый стик ↕»).")
                                .font(.callout)
                                .foregroundColor(.secondary)
                                .padding(.bottom, 4)
                            ForEach(engine.controls) { info in
                                ControlRow(info: info).id(info.key)
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: engine.foundKey) { k in
                        if let k = k {
                            withAnimation { proxy.scrollTo(k, anchor: .center) }
                        }
                    }
                }
            }
        }
    }
}

struct ControlRow: View {
    @EnvironmentObject var engine: Engine
    let info: ControlInfo
    @State var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                LiveBar(live: engine.live, info: info)
                TextField(info.defaultName, text: engine.labelBinding(info.key))
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 210)
                Text(info.kind.title).font(.caption).foregroundColor(.secondary).frame(width: 95, alignment: .leading)
                Text(engine.summary(info))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Button(expanded ? "Свернуть" : "Назначить…") { expanded.toggle() }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(info.zones, id: \.self) { z in
                        HStack(alignment: .top, spacing: 8) {
                            ZoneDot(live: engine.live, key: info.key, zone: z)
                                .padding(.top, 5)
                            Text(z.title)
                                .frame(width: 200, alignment: .leading)
                                .padding(.top, 3)
                            ActionEditor(action: engine.actionBinding(info, z))
                        }
                    }
                    if info.kind == .axis {
                        Text("Границы положений: ±\(Int(engine.config.mouse.zoneThreshold * 100))% (меняется во вкладке «Мышь»). Зелёная точка — текущее положение.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(.leading, 20)
                .padding(.bottom, 4)
            }
        }
        .padding(8)
        .background(RecentHighlight(live: engine.live, key: info.key))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor, lineWidth: engine.foundKey == info.key ? 2 : 0)
        )
        .onChange(of: engine.foundKey) { k in
            if k == info.key { expanded = true }
        }
    }
}

struct RecentHighlight: View {
    @ObservedObject var live: LiveState
    let key: String
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(live.recent.contains(key) ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.07))
    }
}

struct ZoneDot: View {
    @ObservedObject var live: LiveState
    let key: String
    let zone: Zone
    var body: some View {
        Circle()
            .fill(live.zones[key] == zone ? Color.green : Color.gray.opacity(0.3))
            .frame(width: 10, height: 10)
    }
}

struct LiveBar: View {
    @ObservedObject var live: LiveState
    let info: ControlInfo

    var body: some View {
        HStack(spacing: 6) {
            switch info.kind {
            case .axis:
                AxisBar(value: live.values[info.key] ?? 0).frame(width: 130, height: 10)
            case .button:
                Circle()
                    .fill((live.values[info.key] ?? 0) > 0.5 ? Color.green : Color.gray.opacity(0.3))
                    .frame(width: 14, height: 14)
                    .frame(width: 130, alignment: .center)
            case .hat:
                Text(live.zones[info.key].map { $0.short + " " + $0.title } ?? "центр")
                    .frame(width: 130, alignment: .center)
            }
            Text(live.raws[info.key].map { "\($0)" } ?? "—")
                .font(.system(.caption, design: .monospaced))
                .frame(width: 52, alignment: .trailing)
        }
    }
}

struct AxisBar: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let mid = w / 2
            let len = min(1, abs(CGFloat(value))) * mid
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.25))
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: len)
                    .offset(x: value >= 0 ? mid : mid - len)
                Rectangle()
                    .fill(Color.primary.opacity(0.6))
                    .frame(width: 1)
                    .offset(x: mid)
            }
        }
    }
}

struct ActionEditor: View {
    @Binding var action: BindAction

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("", selection: $action.type) {
                    ForEach(ActionType.allCases) { t in Text(t.title).tag(t) }
                }
                .labelsHidden()
                .frame(width: 280)

                if action.type.supportsMode {
                    Picker("", selection: $action.mode) {
                        ForEach(PressMode.allCases) { m in Text(m.title).tag(m) }
                    }
                    .labelsHidden()
                    .frame(width: 230)
                }
            }

            if action.type == .key {
                HStack(spacing: 10) {
                    Toggle("⌘ Cmd", isOn: $action.cmd)
                    Toggle("⇧ Shift", isOn: $action.shift)
                    Toggle("⌥ Option", isOn: $action.option)
                    Toggle("⌃ Ctrl", isOn: $action.control)
                    Picker("", selection: $action.keyCode) {
                        ForEach(KeyCatalog.keys, id: \.code) { k in Text(k.name).tag(k.code) }
                    }
                    .labelsHidden()
                    .frame(width: 250)
                }
            }

            if action.type == .media {
                Picker("", selection: $action.media) {
                    ForEach(MediaKey.allCases) { m in Text(m.title).tag(m) }
                }
                .labelsHidden()
                .frame(width: 280)
            }

            if action.type == .shell {
                TextField("Например: open -a Safari   или   open https://youtube.com", text: $action.command)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(maxWidth: 520)
            }
        }
    }
}

// MARK: - Вкладка «Мышь»

struct MouseTab: View {
    @EnvironmentObject var engine: Engine

    private var axes: [ControlInfo] { engine.controls.filter { $0.kind == .axis } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox(label: Text("Режим курсора")) {
                    Picker("", selection: $engine.config.mouse.mode) {
                        ForEach(MouseMode.allCases) { m in Text(m.title).tag(m) }
                    }
                    .pickerStyle(RadioGroupPickerStyle())
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox(label: Text("Какие оси двигают мышь")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Нажмите «Определить» и подвигайте нужным стиком — программа сама поймёт, какая это ось.")
                            .font(.callout).foregroundColor(.secondary)
                        axisRow("Курсор влево/вправо", .x, $engine.config.mouse.xAxis, $engine.config.mouse.invertX)
                        axisRow("Курсор вверх/вниз", .y, $engine.config.mouse.yAxis, $engine.config.mouse.invertY)
                        axisRow("Прокрутка вверх/вниз", .scrollV, $engine.config.mouse.scrollV, $engine.config.mouse.invertScrollV)
                        axisRow("Прокрутка влево/вправо", .scrollH, $engine.config.mouse.scrollH, $engine.config.mouse.invertScrollH)
                        Text("Подсказка: газ (стик без пружины) не подходит для курсора — для него лучше назначить прокрутку в режиме «Абсолютный» или действия по положениям.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .padding(6)
                }

                GroupBox(label: Text("Чувствительность")) {
                    VStack(alignment: .leading, spacing: 8) {
                        slider("Скорость курсора", $engine.config.mouse.speed, 100...5000, "%.0f пикс/с")
                        slider("Скорость прокрутки", $engine.config.mouse.scrollSpeed, 50...4000, "%.0f пикс/с")
                        slider("Мёртвая зона в центре", $engine.config.mouse.deadzone, 0...0.3, "%.2f")
                        slider("Кривая (1 = линейно, больше = точнее в центре)", $engine.config.mouse.curve, 1...3.5, "%.2f")
                        slider("Множитель «Точного режима»", $engine.config.mouse.precisionFactor, 0.05...1, "×%.2f")
                        slider("Множитель «Турбо»", $engine.config.mouse.turboFactor, 1...6, "×%.1f")
                    }
                    .padding(6)
                }

                GroupBox(label: Text("Тумблеры и повторы")) {
                    VStack(alignment: .leading, spacing: 8) {
                        slider("Порог положений «мин/макс»", $engine.config.mouse.zoneThreshold, 0.15...0.8, "±%.2f")
                        slider("Задержка перед повтором", $engine.config.mouse.repeatDelay, 0...1.5, "%.2f с")
                        slider("Интервал повтора", $engine.config.mouse.repeatInterval, 0.02...1, "%.2f с")
                    }
                    .padding(6)
                }

                HStack {
                    Button("Показать файл настроек в Finder") { engine.revealConfig() }
                    Spacer()
                }
            }
            .padding()
        }
    }

    private func axisRow(_ title: String, _ role: AxisRole, _ sel: Binding<String?>, _ inv: Binding<Bool>) -> some View {
        HStack {
            Text(title).frame(width: 190, alignment: .leading)
            if engine.learningRole == role {
                Button("Подвигайте стиком…") { engine.stopLearning() }
                    .foregroundColor(.orange)
                    .frame(width: 170)
            } else {
                Button("🎯 Определить") { engine.learnAxis(role) }
                    .frame(width: 170)
            }
            Picker("", selection: sel) {
                Text("— не используется —").tag(String?.none)
                ForEach(axes) { a in Text(engine.label(a)).tag(Optional(a.key)) }
            }
            .labelsHidden()
            .frame(width: 260)
            Toggle("Инвертировать", isOn: inv)
            Spacer()
        }
    }

    private func slider(_ title: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, _ fmt: String) -> some View {
        HStack {
            Text(title).frame(width: 330, alignment: .leading)
            Slider(value: v, in: r).frame(width: 300)
            Text(String(format: fmt, v.wrappedValue))
                .font(.system(.body, design: .monospaced))
                .frame(width: 120, alignment: .leading)
            Spacer()
        }
    }
}

// MARK: - Вкладка «Калибровка»

struct CalibrationTab: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var live: LiveState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Калибровка нужна, если курсор едет сам по себе, не доходит до максимальной скорости или тумблеры определяются неправильно.")
                Text("1. Нажмите «Начать калибровку».\n2. Подвигайте ОБА стика по кругу до упора, газ — от минимума до максимума, все тумблеры — во все положения.\n3. Отпустите стики в центр (газ тоже поставьте в середину) и нажмите «Завершить».")
                    .foregroundColor(.secondary)

                HStack {
                    if engine.calibrating {
                        Button("Завершить калибровку") { engine.finishCalibration() }
                        Button("Отмена") { engine.cancelCalibration() }
                        Text("Идёт калибровка…").foregroundColor(.orange)
                    } else {
                        Button("Начать калибровку") { engine.startCalibration() }
                    }
                    Divider().frame(height: 18)
                    Button("Запомнить текущие центры стиков") { engine.captureCenters() }
                    Button("Сбросить калибровку") { engine.resetCalibration() }
                }

                Divider()

                ForEach(engine.controls.filter { $0.kind == .axis }) { info in
                    HStack(spacing: 12) {
                        Text(engine.label(info)).frame(width: 220, alignment: .leading)
                        AxisBar(value: live.values[info.key] ?? 0).frame(width: 160, height: 10)
                        Text("сейчас: \(live.raws[info.key].map { String($0) } ?? "—")")
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 110, alignment: .leading)
                        Text(rangeText(info))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
            }
            .padding()
        }
    }

    private func rangeText(_ info: ControlInfo) -> String {
        if engine.calibrating, let r = live.calRanges[info.key] {
            return "замер: \(r.lowerBound) … \(r.upperBound)"
        }
        if let c = engine.config.calibration[info.key] {
            return "калибровка: \(Int(c.min)) … центр \(Int(c.center)) … \(Int(c.max))"
        }
        return "по умолчанию: \(info.logicalMin) … \(info.logicalMax)"
    }
}

struct CopyReportButton: View {
    @EnvironmentObject var engine: Engine
    @State var copied = false
    var body: some View {
        Button(copied ? "✓ Скопировано" : "📋 Скопировать отчёт") {
            engine.copyDiagnostics()
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
        }
        .help("Копирует список всех входов пульта и последние события — пришлите его, если что-то не работает")
    }
}

// MARK: - Справка

struct HelpTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Group {
                    Text("Как начать").font(.title3).bold()
                    Text("1. Подключите T8L к Mac кабелем USB-C. Если пульт предложит режим USB — выберите джойстик (Joystick / HID / Simulator).")
                    Text("2. Разрешите программе «Универсальный доступ»: Системные настройки → Конфиденциальность и безопасность → Универсальный доступ → включите T8LMouse.")
                    Text("3. Вкладка «Мышь»: нажмите «🎯 Определить» и подвигайте стиком, который будет мышью. Если курсор едет наоборот — «Инвертировать».")
                    Text("4. Вкладка «Кнопки и тумблеры»: «🔍 Найти кнопку на пульте» → щёлкните тумблером → выберите действие для каждого положения.")
                }
                Group {
                    Text("Режимы нажатия").font(.title3).bold().padding(.top, 6)
                    Text("• Один раз при включении — действие срабатывает, когда тумблер/кнопка переходит в это положение.")
                    Text("• Удерживать, пока активно — например, левая кнопка мыши зажата, пока тумблер в этом положении (удобно для перетаскивания).")
                    Text("• Повторять, пока активно — автокликер / автоповтор клавиши.")
                }
                Group {
                    Text("Полезные примеры").font(.title3).bold().padding(.top, 6)
                    Text("• Mission Control: клавиша ↑ + ⌃ Ctrl.   • Переключение окон: ⌘ Cmd + Tab.   • Скриншот: ⌘ + ⇧ + 4.")
                    Text("• Открыть программу: «Команда» → open -a \"Google Chrome\".")
                    Text("• Тумблер на «Вкл/выкл управление» — чтобы быстро отключать пульт (работает, даже когда управление выключено).")
                    Text("• Тумблер на «Точный режим» с «удерживать» — медленный курсор для точного прицеливания.")
                }
                Group {
                    Text("Если что-то не работает").font(.title3).bold().padding(.top, 6)
                    Text("• Курсор не двигается, но значения на вкладке меняются → нет разрешения «Универсальный доступ». После пересборки программы его нужно выдать заново (удалите старую запись кнопкой «−» и добавьте снова).")
                    Text("• Пульт не виден → проверьте кабель (некоторые кабели только заряжают) и режим USB на пульте.")
                    Text("• Курсор сам уплывает → вкладка «Калибровка» или увеличьте мёртвую зону.")
                    Text("• Кнопка/тумблер не реагирует → понажимайте её, затем «📋 Скопировать отчёт» на вкладке «Кнопки и тумблеры» и пришлите текст.")
                    Text("• На T8L кнопки SA и SD — без фиксации: обычно «минимум» = отпущена, «максимум» = нажата. Назначайте действие на «максимум» и режим «Удерживать» или «Один раз».")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}
