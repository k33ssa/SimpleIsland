import SwiftUI
import IslandCore

/// Раздел «Полка» в окне настроек: срок хранения, цели (набор и порядок), куда класть результаты, формат конвертера.
struct ShelfSettingsView: View {
    @ObservedObject var model: ShelfModel

    private static let ttlChoices: [(Int, String)] = [
        (1, "1 час"), (6, "6 часов"), (24, "Сутки"), (72, "3 дня"), (168, "Неделя"), (0, "Не удалять"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Сколько файлы лежат на полке", selection: $model.prefs.ttlHours) {
                        ForEach(Self.ttlChoices.indices, id: \.self) { i in
                            Text(Self.ttlChoices[i].1).tag(Self.ttlChoices[i].0)
                        }
                        if !Self.ttlChoices.contains(where: { $0.0 == model.prefs.ttlHours }) {
                            Text("\(model.prefs.ttlHours) ч").tag(model.prefs.ttlHours)
                        }
                    }
                    Text("Полка хранит копии в ~/Library/Application Support/SimpleIsland/Shelf. Файл убирается, когда выйдет срок (новый срок применяется сразу). ⌥-щелчок по карточке убирает файл в Корзину.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Открыть папку полки") { model.openShelfFolder() }
                        Button("Очистить полку") { model.clear() }.disabled(model.items.isEmpty)
                    }
                }
                .padding(6)
            } label: { Text("Хранение").font(.headline) }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.prefs.order.enumerated()), id: \.element) { i, t in
                        HStack(spacing: 10) {
                            Toggle(isOn: Binding(
                                get: { !model.prefs.hidden.contains(t) },
                                set: { on in
                                    if on { model.prefs.hidden.removeAll { $0 == t } }
                                    else if !model.prefs.hidden.contains(t) { model.prefs.hidden.append(t) }
                                }
                            )) {
                                Label(t.settingsTitle, systemImage: t.systemImage)
                            }
                            Spacer()
                            Button { move(i, by: -1) } label: { Image(systemName: "chevron.up") }
                                .buttonStyle(.borderless).disabled(i == 0).help("Выше")
                            Button { move(i, by: 1) } label: { Image(systemName: "chevron.down") }
                                .buttonStyle(.borderless).disabled(i == model.prefs.order.count - 1).help("Ниже")
                        }
                    }
                    Text("Плитки появляются во вкладке, когда тащишь файлы к острову; щелчок по плитке применяет её к выбранным файлам полки (без выбора — подсказка). Неподходящие по типу файлы пропускаются. Бросок мимо плиток — на полку.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
            } label: { Text("Цели броска").font(.headline) }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Результаты (ZIP, конвертер, «Без фона»)", selection: $model.prefs.placement) {
                        ForEach(ShelfPlacement.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Картинки конвертировать в", selection: $model.prefs.convertFormat) {
                        ForEach(ShelfConvertFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text("PDF всегда превращается в PNG постранично. «Текст» кладёт распознанное (русский и английский) в буфер обмена.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
            } label: { Text("Обработка").font(.headline) }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Скрипты .sh из папки действий получают пути файлов аргументами ($1, $2, …). Последняя строка вывода показывается в уведомлении; когда скрипт закончился, запущенное им в фоне (cmd &) тоже завершается — программу, которая должна остаться работать, запускайте через open. Команды Shortcuts получают файлы на вход.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Открыть папку действий") { model.openActionsFolder() }
                        Button("Обновить список Shortcuts") { model.refreshShortcuts() }
                    }
                    let n = model.scripts.count, m = model.shortcuts.count
                    Text("Скриптов: \(n) · команд Shortcuts: \(m)").font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
            } label: { Text("Свои действия").font(.headline) }
        }
    }

    private func move(_ i: Int, by d: Int) {
        let j = i + d
        guard model.prefs.order.indices.contains(j) else { return }
        model.prefs.order.swapAt(i, j)
    }
}
