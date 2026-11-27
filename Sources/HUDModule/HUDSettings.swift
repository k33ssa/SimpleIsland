import SwiftUI
import IslandCore

/// Настройки модуля HUD (settings.json → moduleSettings["hud"]). Отсутствующие поля — по умолчанию.
struct HUDPrefs: Codable, Equatable {
    /// Глотать клавиши громкости/яркости/подсветки и показывать только свою вспышку (нужен Универсальный доступ).
    /// Действует, только если пользователь выбирал сам (`replaceSystemHUDChosen`); иначе — `replaces(axGranted:)`.
    var replaceSystemHUD = false
    /// Пользователь сам переключал «Заменять системные индикаторы». Нет — замена включена, когда есть Универсальный
    /// доступ (15.11.2026: «квадраты, от которых мы избавлялись, остались» — по умолчанию было выключено, а в
    /// settings.json у всех записано `false`, потому что модуль сохраняет настройки целиком).
    var replaceSystemHUDChosen = false
    var volume = true
    var brightness = true
    var keyboard = true
    var charging = true
    var lowBattery = true
    var headphones = true
    var layout = true
    var capsLock = true
    var camera = true
    var microphone = true
    /// Сеть пропала/появилась. VPN — не здесь: статус VPN даёт отдельный модуль (Vafa); старый ключ `vpn`
    /// в settings.json просто игнорируется.
    var network = true
    /// Подсветку клавиатуры — всегда сегментами (как на железе), а не общим стилем полосы.
    var keyboardSegments = true
    /// Пока камера/микрофон работают — держать точку в компакте (а не только вспышку при включении).
    var captureActivity = false

    init() {}

    /// Заменять ли системные индикаторы сейчас: выбор пользователя, а без выбора — «да, если есть доступ».
    func replaces(axGranted: Bool) -> Bool { replaceSystemHUDChosen ? replaceSystemHUD : axGranted }

    /// Переключатель «Заменить системные индикаторы»: запомнить выбор.
    mutating func setReplaces(_ on: Bool) { replaceSystemHUD = on; replaceSystemHUDChosen = true }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HUDPrefs()
        func v(_ k: CodingKeys, _ def: Bool) -> Bool {
            if let x = try? c.decodeIfPresent(Bool.self, forKey: k) { return x }
            return def
        }
        replaceSystemHUD = v(.replaceSystemHUD, d.replaceSystemHUD)
        replaceSystemHUDChosen = v(.replaceSystemHUDChosen, d.replaceSystemHUDChosen)
        volume = v(.volume, d.volume)
        brightness = v(.brightness, d.brightness)
        keyboard = v(.keyboard, d.keyboard)
        charging = v(.charging, d.charging)
        lowBattery = v(.lowBattery, d.lowBattery)
        headphones = v(.headphones, d.headphones)
        layout = v(.layout, d.layout)
        capsLock = v(.capsLock, d.capsLock)
        camera = v(.camera, d.camera)
        microphone = v(.microphone, d.microphone)
        network = v(.network, d.network)
        keyboardSegments = v(.keyboardSegments, d.keyboardSegments)
        captureActivity = v(.captureActivity, d.captureActivity)
    }
}

/// Наблюдаемое состояние для окна настроек: настройки + права + что доступно на этом Маке.
@MainActor
final class HUDSettingsModel: ObservableObject {
    @Published var prefs: HUDPrefs {
        didSet { if prefs != oldValue { onPrefsChange?(prefs) } }
    }
    @Published var accessibilityGranted = AccessibilityAccess.isTrusted
    @Published var bluetoothAccess = BluetoothWatcher.access
    @Published var tapRunning = false
    @Published var brightnessAvailable = false
    @Published var keyboardAvailable = false
    @Published var hasBattery = true

    var onPrefsChange: ((HUDPrefs) -> Void)?
    var onRequestAccessibility: (() -> Void)?
    var onRequestBluetooth: (() -> Void)?
    var onPreview: ((String) -> Void)?
    /// Окно настроек открыли — перепроверить права (их могли выдать в Системных настройках).
    var onAppear: (() -> Void)?

    init(prefs: HUDPrefs) { self.prefs = prefs }
}

struct HUDSettingsView: View {
    @ObservedObject var model: HUDSettingsModel
    @ObservedObject var settings: SimpleIslandSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("Системные индикаторы") {
                Toggle("Заменить системные индикаторы", isOn: Binding(
                    get: { model.prefs.replaces(axGranted: model.accessibilityGranted) },
                    set: { on in
                        model.prefs.setReplaces(on)
                        if on && !model.accessibilityGranted { model.onRequestAccessibility?() }
                    }))
                Text("Клавиши громкости (и Mute), яркости и подсветки обрабатывает остров: системный квадрат посреди "
                     + "экрана не появляется. Шаг — 1/16, с ⌥⇧ — 1/64; ⌥ + клавиша по-прежнему открывает настройки. "
                     + "Нужен Универсальный доступ; есть доступ — включено само. Выключено — остров только показывает "
                     + "изменения, а системный квадрат остаётся.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                permissionRow(granted: model.accessibilityGranted,
                              okText: model.prefs.replaces(axGranted: model.accessibilityGranted)
                                ? (model.tapRunning ? "Универсальный доступ есть — клавиши перехватываются"
                                                    : "Универсальный доступ есть, перехват не запустился")
                                : "Универсальный доступ есть",
                              needText: "Нужен Универсальный доступ: без него остров не видит клавиши яркости, "
                                + "подсветки и Caps Lock и не может заменить системный индикатор. Громкость, "
                                + "зарядка и остальное работают и так.",
                              action: { model.onRequestAccessibility?() })
            }
            group("Стиль полосы") {
                Picker("Стиль полосы", selection: $settings.data.hudStyle) {
                    ForEach(HUDBarStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Toggle("Подсветку клавиатуры — всегда сегментами", isOn: $model.prefs.keyboardSegments)
                HStack {
                    Text("Показать пример").foregroundStyle(.secondary)
                    Spacer()
                    Button("Громкость") { model.onPreview?("volume") }
                    Button("Зарядка") { model.onPreview?("charging") }
                    Button("Раскладка") { model.onPreview?("layout") }
                }
            }
            group("Что показывать") {
                Toggle("Громкость и имя устройства вывода", isOn: $model.prefs.volume)
                Toggle(isOn: $model.prefs.brightness) {
                    label("Яркость встроенного экрана", note: model.brightnessAvailable ? nil : "встроенный экран выключен или недоступен")
                }
                .disabled(!model.brightnessAvailable)
                Toggle(isOn: $model.prefs.keyboard) {
                    label("Подсветка клавиатуры", note: model.keyboardAvailable ? nil : "не удалось подключиться — отключено")
                }
                .disabled(!model.keyboardAvailable)
                Toggle(isOn: $model.prefs.charging) {
                    label("Зарядка: подключили и отключили", note: model.hasBattery ? nil : "нет батареи")
                }
                Toggle("Мало заряда (20 % и 10 %)", isOn: $model.prefs.lowBattery)
                Toggle(isOn: $model.prefs.headphones) {
                    label("Наушники и AirPods подключились", note: bluetoothNote)
                }
                if model.prefs.headphones, model.bluetoothAccess == .notDetermined || model.bluetoothAccess == .denied {
                    HStack {
                        Text(model.bluetoothAccess == .denied ? "Bluetooth запрещён в Конфиденциальности."
                                                              : "Нужно разрешение на Bluetooth.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Разрешить…") { model.onRequestBluetooth?() }
                    }
                    .font(.callout)
                }
                Toggle("Раскладка RU / EN", isOn: $model.prefs.layout)
                Toggle(isOn: $model.prefs.capsLock) {
                    label("Caps Lock", note: model.accessibilityGranted ? nil : "нужен Универсальный доступ")
                }
                Toggle("Камера включилась", isOn: $model.prefs.camera)
                Toggle("Микрофон включился (с именем приложения)", isOn: $model.prefs.microphone)
                Toggle("Держать значок, пока камера или микрофон работают", isOn: $model.prefs.captureActivity)
                    .disabled(!model.prefs.camera && !model.prefs.microphone)
                Toggle("Сеть пропала / появилась", isOn: $model.prefs.network)
            }
            Text("Фокус не показывается: публично macOS говорит только «фокус вкл/выкл» и лишь приложениям с особым "
                 + "разрешением Apple; какой режим и до скольки — только с Полным доступом к диску.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .onAppear { model.onAppear?() }
    }

    private var bluetoothNote: String? {
        switch model.bluetoothAccess {
        case .granted: return nil
        case .notDetermined: return "нужно разрешение"
        case .denied: return "Bluetooth запрещён"
        case .unavailable: return "только в собранном .app"
        }
    }

    @ViewBuilder private func label(_ title: String, note: String?) -> some View {
        HStack(spacing: 6) {
            Text(title)
            if let note { Text("— \(note)").foregroundStyle(.secondary) }
        }
    }

    private func permissionRow(granted: Bool, okText: String, needText: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
            Text(granted ? okText : needText).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if !granted { Button("Разрешить…", action: action) }
        }
        .font(.callout)
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}
