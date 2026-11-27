import AppKit
import IslandCore
import SwiftUI

/// Раздел «Медиа» в окне настроек.
struct MediaSettingsView: View {
    @ObservedObject var model: MediaModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            group {
                Picker("Источник", selection: $model.prefs.source) {
                    ForEach(MediaSourcePreference.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(sourceNote).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !MediaRemoteSource.isAvailable {
                    // Отладочная сборка (`swift build`) помощника не собирает — scripts/build-media-helper.sh.
                    Label("Помощник MediaRemote не найден — работает только AppleScript (Музыка, Spotify).",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            group {
                Toggle("Строка текста песни в свёрнутом острове", isOn: $model.prefs.compactLyrics)
                Toggle("Показывать вкладку, когда начинается воспроизведение", isOn: $model.prefs.openOnPlay)
                Toggle("Короткая вспышка с названием при смене трека", isOn: $model.prefs.flashOnTrackChange)
            }
            mediaKeysGroup
            group { LyricsSettingsSection(model: model) }
            group {
                Picker("Вид эквалайзера в свёрнутом острове", selection: $model.prefs.eqStyle) {
                    Text("№8 · Отражение").tag(VisualizerStyle.reflection)
                    Text("№1 · Капсулы с инерцией").tag(VisualizerStyle.capsules)
                    Text("№3 · Ореол по громкости").tag(VisualizerStyle.halo)
                    Text("Классика").tag(VisualizerStyle.classic)
                }
                Toggle("Эквалайзер по реальному звуку", isOn: Binding(
                    get: { model.prefs.liveVisualizer },
                    set: { model.setLiveVisualizer($0) }))
                Text("Полоски в свёрнутом острове двигаются по звуку, который играет (как у iPhone). Нужно право «Запись системного звука»; звук не записывается и никуда не отправляется — считаются только уровни, и только пока остров с музыкой виден.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.prefs.liveVisualizer {
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.liveAudioStatusText)
                            .font(.callout)
                            .foregroundStyle(model.audioPermission == .denied ? Color.orange : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if model.audioPermission != .granted {
                            Button("Разрешить…") { model.setLiveVisualizer(true) }
                        }
                    }
                }
            }
            .onAppear { model.refreshAudioPermission() }
            group {
                HStack {
                    Text("Разрешение «Автоматизация»")
                    Spacer()
                    Button("Открыть настройки…") { ScriptSource.openAutomationSettings() }
                }
                Text("Нужно для Музыки и Spotify, если MediaRemote недоступен, и для лайка в Музыке. Без него плеер показывает то, что приложения сообщают сами, без обложки и позиции.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
    }

    // --- keys --- медиаклавиши ⏯ ⏭ ⏮ → последнему музыкальному приложению.
    @State private var axGranted = AXIsProcessTrusted()

    @ViewBuilder private var mediaKeysGroup: some View {
        group {
            Toggle("Медиаклавиши управляют музыкой", isOn: $model.prefs.mediaKeys)
            Picker("Клавиши ⏯ ⏭ ⏮", selection: $model.prefs.mediaKeysTarget) {
                ForEach(MediaKeysTarget.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(!model.prefs.mediaKeys)
            Text(keysNote).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.prefs.wantsMediaKeys {
                if !axGranted {
                    HStack(alignment: .firstTextBaseline) {
                        Label("Нужен Универсальный доступ — пока клавиши работают как в системе.",
                              systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Разрешить…") {
                            Task { @MainActor in
                                _ = await Permissions.requestFromUser(.accessibility, moduleId: "media")
                                axGranted = AXIsProcessTrusted()
                            }
                        }
                    }
                } else if let b = model.prefs.lastMusicBundle, MusicApps.scriptable(b), model.keysAutomation == .denied {
                    HStack(alignment: .firstTextBaseline) {
                        Label("Нет права «Автоматизация» для \(model.prefs.lastMusicName ?? b) — клавиши уходят системе.",
                              systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Разрешить…") {
                            Task { @MainActor in
                                _ = await Permissions.requestFromUser(.automation(bundleId: b), moduleId: "media")
                                model.refreshKeysAutomation()
                            }
                        }
                    }
                }
            }
        }
        .onAppear { axGranted = AXIsProcessTrusted(); model.refreshKeysAutomation() }
    }

    private var keysNote: String {
        guard model.prefs.wantsMediaKeys else {
            return "Клавиши идут приложению, которое последним сообщило «что играет» (так делает macOS) — например, видео на паузе в браузере."
        }
        let app = model.prefs.lastMusicName.map { "Сейчас это: \($0)." } ?? "Музыка ещё не играла — пока клавиши работают как в системе."
        return "Клавиши идут приложению, где последней играла музыка, даже если в браузере стоит на паузе видео. Пока видео реально играет — как в системе. Удержание ⏭/⏮ — перемотка. \(app)"
    }

    private var sourceNote: String {
        switch model.prefs.source {
        case .auto: return "Любое приложение через MediaRemote; если он недоступен — Музыка и Spotify через AppleScript."
        case .music: return "Только Музыка."
        case .spotify: return "Только Spotify."
        case .any: return "Любое приложение (браузеры, плееры) только через MediaRemote, без AppleScript."
        }
    }

    @ViewBuilder private func group<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { c() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}
