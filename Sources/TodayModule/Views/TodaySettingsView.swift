import AppKit
import EventKit
@preconcurrency import AVFoundation
import SwiftUI
import IslandCore

/// Раздел «Сегодня» в окне настроек: плитки (вкл/порядок), город погоды, буфер, «Не беспокоить», права.
struct TodaySettingsView: View {
    @ObservedObject var model: TodayModel
    @State private var query = ""
    @State private var places: [WeatherAPI.Place] = []
    @State private var searching = false
    @State private var searchError: String?
    /// Перечитать статусы прав после «Разрешить…» (статус камеры — не @Published).
    @State private var permissionsTick = 0
    @State private var automationStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            card("Плитки") {
                Text("Порядок — слева направо, сверху вниз. Плитки встают в ряд по ширине (событие и буфер шире остальных); что не влезло — переносится в следующий ряд.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(Array(model.prefs.tiles.enumerated()), id: \.element.id) { i, s in
                    HStack(spacing: 10) {
                        Toggle(isOn: Binding(get: { model.prefs.tiles[i].enabled },
                                             set: { model.prefs.tiles[i].enabled = $0 })) {
                            Label(s.tile.title, systemImage: s.tile.systemImage)
                        }
                        Spacer()
                        Button { move(i, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(i == 0).help("Выше")
                        Button { move(i, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(i == model.prefs.tiles.count - 1).help("Ниже")
                    }
                    .buttonStyle(.borderless)
                }
            }

            card("Погода") {
                HStack {
                    Text("Город: **\(model.prefs.cityName)**")
                    Text(String(format: "%.2f, %.2f", model.prefs.latitude, model.prefs.longitude))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                HStack {
                    TextField("Найти город", text: $query).onSubmit(search).frame(maxWidth: 240)
                    Button(searching ? "Ищу…" : "Найти", action: search).disabled(searching || query.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let e = searchError { Text(e).font(.callout).foregroundStyle(.red) }
                ForEach(places) { p in
                    Button {
                        model.prefs.cityName = p.name
                        model.prefs.latitude = (p.latitude * 100).rounded() / 100
                        model.prefs.longitude = (p.longitude * 100).rounded() / 100
                        places = []; query = ""
                    } label: {
                        HStack { Text(p.name); Text(p.subtitle).foregroundStyle(.secondary) }
                    }
                    .buttonStyle(.link)
                }
                Text("Прогноз — open-meteo.com без ключа, раз в 30 минут и только пока вкладка открыта. На сервер уходят координаты города, не твоё место.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            card("Буфер обмена") {
                Toggle("Помнить историю между запусками", isOn: $model.prefs.rememberClipboard)
                Text("Последние 20 записей. По умолчанию — только в памяти. Если включить, текст хранится в файле с доступом только для тебя; пароли (пометка менеджеров паролей) и строки, похожие на токены, не сохраняются.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            card("Не беспокоить") {
                TextField("Имя ярлыка «Быстрых команд» (пусто — искать «Не беспокоить», «Set Focus»…)", text: $model.prefs.focusShortcut)
                if let n = model.focusShortcutName {
                    Text("Ярлык «\(n)» найден — тумблер «Тишина» его запускает.").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Ярлык не найден — тумблер «Тишина» скрыт. Создай в «Быстрых командах» ярлык с действием «Задать фокус» (переключить «Не беспокоить») и назови его, например, «Не беспокоить».")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            card("Быстрые тумблеры") {
                ForEach(ToggleKind.allCases) { k in
                    Toggle(isOn: Binding(get: { !model.prefs.hiddenToggles.contains(k.rawValue) },
                                         set: { on in
                                             model.prefs.hiddenToggles.removeAll { $0 == k.rawValue }
                                             if !on { model.prefs.hiddenToggles.append(k.rawValue) }
                                         })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(k.title)
                            Text(k.help).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            card("Права") {
                permissionRow("Календарь", ok: model.calendarAccess == .granted,
                              status: model.calendarAccess == .granted ? "разрешено" : (model.calendarAccess == .notDetermined ? "не спрашивали" : "нет доступа")) {
                    model.requestCalendar()
                }
                let cam = CameraMirror.authorization
                permissionRow("Камера (зеркало)", ok: cam == .authorized ? true : (cam == .notDetermined ? nil : false),
                              status: cam == .authorized ? "разрешено" : (cam == .notDetermined ? "не спрашивали" : "нет доступа")) {
                    CameraMirror.requestAccessOrOpenSettings { permissionsTick += 1 }
                }
                .id(permissionsTick)
                permissionRow("Автоматизация (тёмная тема)", ok: automationStatus == "разрешено" ? true : nil,
                              status: automationStatus ?? "спросим при первом переключении") {
                    // Право — через ядро (`ensurePermission`): не спрашивали — окно, отказ — Системные настройки;
                    // System Events не запущен — безвредное чтение (macOS покажет запрос сама). См. TodayModel.
                    automationStatus = "проверяю…"
                    Task { @MainActor in
                        switch await model.requestAutomation() {
                        case .granted: automationStatus = "разрешено"
                        case .denied, .notDetermined: automationStatus = "нет доступа"
                        case .unknown: automationStatus = "System Events не ответили"
                        }
                    }
                }
            }
        }
    }

    private func move(_ i: Int, by d: Int) {
        let j = i + d
        guard model.prefs.tiles.indices.contains(j) else { return }
        model.prefs.tiles.swapAt(i, j)
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true; searchError = nil
        Task { @MainActor in
            do {
                places = try await WeatherAPI.searchCity(q)
                if places.isEmpty { searchError = "Ничего не нашлось" }
            } catch {
                searchError = "Нет сети или сервис недоступен"
            }
            searching = false
        }
    }

    private func permissionRow(_ title: String, ok: Bool?, status: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok == true ? "checkmark.circle.fill" : (ok == false ? "exclamationmark.circle" : "questionmark.circle"))
                .foregroundStyle(ok == true ? .green : .secondary)
            Text(title)
            Text(status).foregroundStyle(.secondary)
            Spacer()
            if ok != true { Button("Разрешить…", action: action) }
        }
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}
