import Combine
import SwiftUI
import IslandCore

/// Виджет «Эквалайзер» (15.11, «добавь мне эквалайзер виджетом»): отдельная вкладка с большим спектром по настоящему
/// звуку. Своего захвата нет — та же модель «Медиа» (`MediaModel`): общий `AudioLevelsFeed` и `LiveAudioController`.
/// Захват звука идёт только пока полоски видны и анимированы (вкладка открыта, что-то играет, полное движение):
/// полоски подписываются на канал уровней (`addSink`) лишь в окне — без спроса контроллер освобождает tap.
/// По умолчанию не на острове — добавляется из каталога виджетов.
///
/// 15.11 («а что делает-то эквалайзер, вроде ничего оттуда нельзя делать»): под спектром — встроенный эквалайзер
/// «Музыки» (`MusicEqualizer`, AppleScript): вкл/выкл и пресеты кнопками. У Spotify и браузеров эквалайзера в
/// AppleScript нет — вкладка так и пишет, остаётся только спектр.
@MainActor
public final class EqualizerIslandModule: IslandModule {
    nonisolated public static let moduleId = "equalizer"
    public let id = EqualizerIslandModule.moduleId
    public let title = "Эквалайзер"
    public let systemImage = "waveform"
    public var providesTab: Bool { true }
    public var tabEnabledByDefault: Bool { false }
    /// 16.11: +ряд своих пресетов и редактор полос — 280 (было 256).
    public var expandedHeight: CGFloat { 280 }

    let model: MediaModel
    let music = MusicEqualizer()
    private weak var context: ModuleContext?

    init(model: MediaModel) {
        self.model = model
        // Свои пресеты — в настройках «Медиа» (`MediaPrefs.customEQ`); модель «Медиа» грузит их при старте.
        music.store = (load: { [weak model] in model?.prefs.customEQ ?? [] },
                       save: { [weak model] list in
                           guard let model, model.prefs.customEQ != list else { return }
                           model.prefs.customEQ = list
                       })
    }

    /// Модель запускает и останавливает модуль «Медиа» (он стартует всегда, даже со скрытой вкладкой).
    public func start(context: ModuleContext) { self.context = context }
    public func stop() {
        music.flush()
        context?.requestKeyboard(false)
        context?.releaseAllExpandHolds()
    }

    public func expandedView() -> AnyView? {
        AnyView(EqualizerExpandedView(model: model, music: music,
                                      keyboard: { [weak self] on in self?.ctx?.requestKeyboard(on) },
                                      hold: { [weak self] on in
                                          guard let c = self?.ctx else { return }
                                          if on { c.holdExpanded("eq-drag", timeout: 30) } else { c.releaseExpanded("eq-drag") }
                                      }))
    }

    private var ctx: ModuleContext? { context ?? model.context }
    public func settingsView() -> AnyView? { nil }

    public func snapshotStates() -> [ModuleSnapshot] {
        [
            ModuleSnapshot("playing", presentation: .expanded) { ctx in
                self.prepare(ctx, permission: .granted)
                self.music.mock(.init(enabled: true, current: "Rock", presets: MusicEqualizer.mockPresets), access: .ready, customs: [])
                self.model.applyMock(MediaMocks.track(playing: true), placeholder: .warm, lyrics: nil)
            },
            ModuleSnapshot("music-off", presentation: .expanded) { ctx in
                self.prepare(ctx, permission: .granted)
                self.music.mock(.init(enabled: false, current: "Rock", presets: MusicEqualizer.mockPresets), access: .ready)
                self.model.applyMock(MediaMocks.track(playing: true), placeholder: .sea, lyrics: nil)
            },
            ModuleSnapshot("music-permission", presentation: .expanded) { ctx in
                self.prepare(ctx, permission: .granted)
                self.music.mock(nil, access: .needsPermission)
                self.model.applyMock(MediaMocks.track(playing: true), placeholder: .violet, lyrics: nil)
            },
            ModuleSnapshot("spotify", presentation: .expanded) { ctx in
                self.prepare(ctx, permission: .granted)
                self.music.mock(nil, access: .notRunning)
                var t = MediaMocks.track(playing: true)
                t.bundleId = MediaApps.spotify; t.appName = "Spotify"
                self.model.applyMock(t, placeholder: .warm, lyrics: nil)
            },
            ModuleSnapshot("permission", presentation: .expanded) { ctx in
                self.prepare(ctx, permission: .notDetermined)
                self.music.mock(.init(enabled: true, current: "Pop", presets: MusicEqualizer.mockPresets), access: .ready)
                self.model.applyMock(MediaMocks.track(playing: true), placeholder: .sea, lyrics: nil)
            },
            ModuleSnapshot("silence", presentation: .expanded) { ctx in
                self.prepare(ctx, permission: .granted)
                self.music.mock(nil, access: .notRunning)
                self.model.applyMock(nil, placeholder: nil, lyrics: nil)
            },
            ModuleSnapshot("custom", presentation: .expanded) { ctx in
                self.prepare(ctx, permission: .granted)
                let c = MusicEqualizer.mockCustoms
                self.music.mock(.init(enabled: true, current: c[0].name, presets: MusicEqualizer.mockPresets + c.map(\.name),
                                      currentBands: [c[0].preamp] + c[0].bands), access: .ready, customs: c)
                self.music.editing = nil
                self.model.applyMock(MediaMocks.track(playing: true), placeholder: .warm, lyrics: nil)
            },
            ModuleSnapshot("custom-editor", presentation: .expanded) { ctx in
                self.prepare(ctx, permission: .granted)
                let c = MusicEqualizer.mockCustoms
                self.music.mock(.init(enabled: true, current: c[0].name, presets: MusicEqualizer.mockPresets + c.map(\.name),
                                      currentBands: [c[0].preamp] + c[0].bands), access: .ready, customs: c)
                self.music.editing = c[0].id
                self.music.hotSlider = 2
                self.model.applyMock(MediaMocks.track(playing: true), placeholder: .warm, lyrics: nil)
            },
            ModuleSnapshot("manual", presentation: .expanded) { ctx in
                self.prepare(ctx, permission: .granted)
                let m = MusicEqualizer.mockManualBands
                self.music.mock(.init(enabled: true, current: "Настройка вручную", presets: MusicEqualizer.mockPresetsRu,
                                      currentBands: m, manualName: "Настройка вручную", manualBands: m), access: .ready, customs: [])
                self.model.applyMock(MediaMocks.track(playing: true), placeholder: .warm, lyrics: nil)
            },
            ModuleSnapshot("manual-editor", presentation: .expanded) { ctx in
                self.prepare(ctx, permission: .granted)
                let m = MusicEqualizer.mockManualBands
                self.music.mock(.init(enabled: true, current: "Настройка вручную", presets: MusicEqualizer.mockPresetsRu,
                                      currentBands: m, manualName: "Настройка вручную", manualBands: m), access: .ready, customs: [])
                self.music.editing = MusicEqualizer.manualId
                self.music.hotSlider = 7
                self.model.applyMock(MediaMocks.track(playing: true), placeholder: .warm, lyrics: nil)
            },
            ModuleSnapshot("custom-editor-off", presentation: .expanded) { ctx in
                self.prepare(ctx, permission: .granted)
                let c = MusicEqualizer.mockCustoms
                self.music.mock(.init(enabled: false, current: c[1].name, presets: MusicEqualizer.mockPresets + c.map(\.name),
                                      currentBands: [c[1].preamp] + c[1].bands), access: .ready, customs: c)
                self.music.editing = c[1].id
                self.music.hotSlider = nil
                self.model.applyMock(MediaMocks.track(playing: true), placeholder: .sea, lyrics: nil)
            },
        ]
    }

    private func prepare(_ ctx: ModuleContext, permission: PermissionStatus) {
        music.editing = nil
        music.hotSlider = nil
        // Вкладка по умолчанию выключена — в снимке включить, иначе остров покажет первую включённую.
        if let i = ctx.settings.data.tabs.firstIndex(where: { $0.id == Self.moduleId }) { ctx.settings.data.tabs[i].enabled = true }
        model.context = ctx
        model.isSnapshot = true
        model.mockAudioPermission(permission)
    }
}

/// Что показывает спектр (без вью — для самотеста).
enum EqualizerState: Equatable {
    /// Ничего не играет — низкие полоски.
    case silence
    /// Трек есть, но на паузе (15.11: было «Тишина — ничего не играет» при показанном треке).
    case paused
    /// Играет, полоски по звуку (или псевдо, пока звук не пришёл).
    case live
    /// Эквалайзер по звуку выключен в настройках «Медиа».
    case off
    /// Нет права «Запись системного звука» — кнопка «Разрешить».
    case needsPermission
    /// Играет, право есть, а захват дольше `EqualizerSignalWatch.grace` даёт одни нули — «Нет доступа к звуку».
    case noSignal

    @MainActor static func of(_ m: MediaModel, silentTooLong: Bool = false) -> EqualizerState {
        of(hasTrack: m.now != nil, playing: m.now?.isPlaying == true, liveVisualizer: m.prefs.liveVisualizer,
           permission: m.audioPermission, silentTooLong: silentTooLong)
    }

    static func of(hasTrack: Bool, playing: Bool, liveVisualizer: Bool, permission: PermissionStatus,
                   silentTooLong: Bool) -> EqualizerState {
        guard hasTrack else { return .silence }
        guard playing else { return .paused }
        if !liveVisualizer { return .off }
        if permission != .granted { return .needsPermission }
        return silentTooLong ? .noSignal : .live
    }

    /// Полоски в покое: низкие, но выше своей ширины (не ряд овалов) — пологая «гора», как у затихшего спектра.
    static func restingLevels(count: Int) -> [Double] {
        (0..<count).map { i in
            let x = count > 1 ? Double(i) / Double(count - 1) : 0.5
            return 0.16 + 0.1 * sin(x * .pi) + 0.03 * cos(Double(i) * 1.7)
        }
    }
    /// Ширина полоски в покое, pt: при высоте спектра `h` столбик выше своей ширины хотя бы вдвое.
    static func restingBarWidth(height h: CGFloat, maxWidth: CGFloat) -> CGFloat {
        max(3, min(maxWidth, floor(h * 0.13 / 2)))
    }
}

/// Идёт ли из захвата хоть что-то, кроме нулей: подписка на канал уровней только пока спектр «живой» и вкладка
/// открыта; проверка — раз в секунду общим тикером (`SharedTicker`), без своих таймеров.
@MainActor
final class EqualizerSignalWatch: ObservableObject {
    @Published private(set) var silentTooLong = false
    static let grace: TimeInterval = 4
    static let threshold: Float = 0.02
    private weak var feed: AudioLevelsFeed?
    private var lastSignal = Date()
    private var tick: AnyCancellable?

    static func hasSignal(_ levels: [Float]) -> Bool { (levels.max() ?? 0) > threshold }

    func start(_ feed: AudioLevelsFeed) {
        guard self.feed !== feed || tick == nil else { return }
        stop()
        self.feed = feed
        lastSignal = Date()
        feed.addSink(self) { [weak self] f in
            guard let self, Self.hasSignal(f.wide) else { return }
            self.lastSignal = Date()
            if self.silentTooLong { self.silentTooLong = false }
        }
        tick = SharedTicker.shared.subscribe(every: 1) { [weak self] _ in
            guard let self else { return }
            let silent = Date().timeIntervalSince(self.lastSignal) > Self.grace
            if silent != self.silentTooLong { self.silentTooLong = silent }
        }
    }

    func stop() {
        feed?.removeSink(self)
        feed = nil
        tick = nil
        if silentTooLong { silentTooLong = false }
    }
}

/// Что показать под спектром: управление эквалайзером «Музыки» или честную подпись.
enum EqualizerControls: Equatable {
    /// Играет «Музыка» (или ничего не играет) — её эквалайзер: состояние доступа `MusicEqualizer.Access`.
    case music
    /// Играет другое приложение — эквалайзера у него нет.
    case otherApp(String)

    @MainActor static func of(_ m: MediaModel) -> EqualizerControls {
        guard let now = m.now, !now.isMusicApp else { return .music }
        return .otherApp(now.appName ?? (now.isSpotify ? "Spotify" : "этого плеера"))
    }
}

struct EqualizerExpandedView: View {
    @ObservedObject var model: MediaModel
    @ObservedObject var music: MusicEqualizer
    /// Просить клавиатуру у острова (имя пресета, ↑/↓ над полосой) — только пока открыт редактор.
    var keyboard: (Bool) -> Void = { _ in }
    /// Держать остров раскрытым, пока тянут полосу.
    var hold: (Bool) -> Void = { _ in }
    @Environment(\.islandMotion) private var motion
    @StateObject private var signal = EqualizerSignalWatch()
    @Environment(\.islandTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    static let bars = AudioLevelsFeed.wideCount   // 24 полосы — столько считает спектр, без повторов
    /// Пресетов в ряду сетки.
    static let columns = 6

    var body: some View {
        let colors = MediaColors(theme: theme, palette: model.palette)
        let state = EqualizerState.of(model, silentTooLong: signal.silentTooLong)
        let playing = model.now?.isPlaying == true
        let controls = EqualizerControls.of(model)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                CoverView(image: model.coverImage, placeholder: model.placeholderArtwork, size: 30,
                          radius: theme.mediaRadius(7), shadow: nil, appBadge: nil, videoIcon: model.now?.isVideo == true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.now?.title ?? "Ничего не играет")
                        .font(theme.font(14, .bold)).foregroundStyle(theme.primary).lineLimit(1)
                    Text(model.now.map(\.subtitle) ?? "Включите музыку — полоски оживут")
                        .font(theme.font(11.5, .medium)).foregroundStyle(theme.tertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                spectrumNote(state)
            }
            if let id = editorId(controls) {
                EqualizerEditorHeader(music: music, presetId: id, close: { closeEditor() })
                    .transition(.opacity)
                EqualizerBandsEditor(music: music, presetId: id, hold: hold)
                    .frame(maxHeight: .infinity)
                    .opacity(music.state?.enabled == true ? 1 : 0.6)   // как сетка: выключен — приглушено
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
            } else {
            GeometryReader { g in
                // Полоски не толще 16 pt (иначе тишина — ряд кругов), остаток ширины — в зазоры.
                // В покое — узкие низкие столбики (раньше 16-pt «пилюли» высотой 0,2 выглядели рядом овалов).
                let n = CGFloat(Self.bars)
                let full = max(3, min(16, floor((g.size.width - 4 * (n - 1)) / n)))
                let w = playing ? full : EqualizerState.restingBarWidth(height: g.size.height, maxWidth: full)
                let gap = max(2, floor((g.size.width - w * n) / (n - 1)))
                Visualizer(bars: Self.bars, levels: playing ? nil : EqualizerState.restingLevels(count: Self.bars),
                           animated: playing, height: g.size.height, colors: colors.played,
                           feed: model.prefs.liveVisualizer ? model.audioFeed : nil, barWidth: w, gap: gap)
                    .opacity(playing ? 1 : 0.35)
                    .frame(width: g.size.width, height: g.size.height, alignment: .center)
            }
            .frame(minHeight: 40, maxHeight: controls == .music && music.access == .ready ? 46 : .infinity)
            switch controls {
            case .music: musicControls
            case .otherApp(let name):
                note("Эквалайзер есть только у Музыки — у \(name) его не поменять. Сверху — спектр того, что играет.",
                     systemImage: "info.circle")
            }
            }
        }
        .animation(motion.animation(.spring(response: theme.spring.response, dampingFraction: theme.spring.damping)),
                   value: music.editing)
        .onChange(of: music.editing) { id in if !isSnapshot { keyboard(id != nil) } }
        .onAppear {
            guard !isSnapshot else { return }   // снимок: права и «Музыка» — из мока, не из системы
            model.refreshAudioPermission()
            music.reloadCustoms()
            music.refresh()
        }
        .onChange(of: model.now?.bundleId) { _ in music.refresh() }
        .onChange(of: state == .live || state == .noSignal) { watch in updateSignalWatch(watch) }
        .onAppear { updateSignalWatch(state == .live || state == .noSignal) }
        .onDisappear {
            signal.stop()
            guard !isSnapshot else { return }
            music.flush()
            music.editing = nil
            music.hotSlider = nil
            keyboard(false)
        }
    }

    /// Открыт ли редактор (и есть ли что редактировать): только у «Музыки» с доступом.
    private func editorId(_ controls: EqualizerControls) -> String? {
        guard controls == .music, music.access == .ready, music.state != nil,
              let id = music.editing, music.editable(id) != nil else { return nil }
        return id
    }

    private func closeEditor() {
        music.flush()
        music.hotSlider = nil
        music.editing = nil
    }

    private func updateSignalWatch(_ on: Bool) {
        if on && !isSnapshot { signal.start(model.audioFeed) } else { signal.stop() }
    }

    // MARK: Эквалайзер «Музыки»

    @ViewBuilder private var musicControls: some View {
        switch music.access {
        case .ready:
            if let s = music.state {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Эквалайзер Музыки").font(theme.font(12.5, .semibold)).foregroundStyle(theme.secondary)
                        Spacer(minLength: 0)
                        IslandButton(s.enabled ? "Включён" : "Выключен", systemImage: s.enabled ? "checkmark" : "power",
                                     style: s.enabled ? .accent : .plain, height: 22,
                                     accessibilityLabel: "Эквалайзер Музыки \(s.enabled ? "включён" : "выключен")",
                                     accessibilityHint: s.enabled ? "Выключить" : "Включить") { music.setEnabled(!s.enabled) }
                    }
                    if let why = music.refused {
                        note(why, systemImage: "exclamationmark.triangle")
                    }
                    customRow(enabled: s.enabled)
                    presetGrid(MusicEqualizer.gridOrder(s.presets, excluding: music.customNames.union(music.manual.map { [$0.name] } ?? [])),
                               enabled: s.enabled)
                }
            } else {
                note("Читаю эквалайзер Музыки…", systemImage: "hourglass")
            }
        case .needsPermission, .denied:
            HStack(spacing: 10) {
                note("Чтобы менять эквалайзер Музыки, нужно разрешение «Автоматизация → Музыка».", systemImage: "slider.vertical.3")
                IslandButton(music.access == .denied ? "Открыть настройки" : "Разрешить", style: .accent, height: 24) {
                    music.requestAccess()
                }
                .fixedSize()
            }
        case .notRunning, .unknown:
            HStack(spacing: 10) {
                note("Эквалайзер — у приложения Музыка: открой её, и здесь появятся пресеты.", systemImage: "slider.vertical.3")
                IslandButton("Открыть Музыку", systemImage: "music.note", height: 24) { music.openMusic() }.fixedSize()
            }
        }
    }

    /// Ряд своих пресетов + «+ Свой». Нажатие — выбрать; по выбранному (или «Изменить» в меню) — редактор полос.
    private func customRow(enabled: Bool) -> some View {
        // Без ScrollView: чипы сжимаются (имя — с многоточием), «+ Свой» всегда виден; ScrollView к тому же не
        // рисуется в снимках.
        HStack(spacing: 5) {
                Button {
                    if let id = music.addCustom() { music.editing = id }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                        Text("Свой пресет").font(theme.font(11, .bold))
                    }
                    .foregroundStyle(theme.primary)
                    .padding(.horizontal, 11).frame(height: 22)
                    .background(Capsule().fill(theme.accentColor.opacity(0.18)))
                    .overlay(Capsule().strokeBorder(theme.accentColor.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5])))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Свой пресет: 10 полос и предусилитель, сохранится и в Музыке")
                .accessibilityLabel("Добавить свой пресет")
                .fixedSize()
            // «Настройка вручную» Музыки — тоже с полосами: здесь, рядом со своими, а не в сетке Apple.
            if let m = music.manual { customChip(m) }
            ForEach(music.customs) { c in customChip(c) }
            if music.customs.isEmpty {
                Text("выбранный — нажмите ещё раз, откроются полосы")
                    .font(theme.font(10.5, .medium)).foregroundStyle(theme.tertiary).lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 22)
        .opacity(enabled ? 1 : 0.7)
    }

    private func customChip(_ c: CustomEQPreset) -> some View {
        let on = music.isSelected(c.name)
        return HStack(spacing: 5) {
            EqualizerMiniCurve(bands: c.bands, color: on ? theme.primary : theme.tertiary)
                .frame(width: 18, height: 10)
            Text(c.name).font(theme.font(11, on ? .bold : .semibold)).lineLimit(1).fixedSize()
                .foregroundStyle(on ? theme.primary : theme.secondary)
            if on {
                Image(systemName: "slider.vertical.3").font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(theme.secondary)
            }
        }
        .padding(.horizontal, 10).frame(height: 22)
        .background(Capsule().fill(on ? theme.accentColor.opacity(0.32) : theme.controlFillColor))
        .overlay(Capsule().strokeBorder(on ? theme.accentColor.opacity(0.9) : .clear, lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture { if on { music.editing = c.id } else { music.selectCustom(c.id) } }
        .contextMenu {
            Button("Изменить полосы") { music.selectCustom(c.id); music.editing = c.id }
            if c.id != MusicEqualizer.manualId {
                Button("Удалить «\(c.name)»", role: .destructive) { music.delete(c.id) }
            }
        }
        .help(on ? "«\(c.name)» — нажмите ещё раз, чтобы поменять полосы" : "Свой пресет «\(c.name)»")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(c.id == MusicEqualizer.manualId ? "Пресет Музыки \(c.name), с полосами" : "Свой пресет \(c.name)")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction { music.selectCustom(c.id) }
        .accessibilityAction(named: "Изменить полосы") { music.selectCustom(c.id); music.editing = c.id }
    }

    private func presetGrid(_ presets: [String], enabled: Bool) -> some View {
        VStack(spacing: 5) {
            ForEach(Array(stride(from: 0, to: presets.count, by: Self.columns)), id: \.self) { start in
                HStack(spacing: 5) {
                    ForEach(start..<start + Self.columns, id: \.self) { i in
                        if i < presets.count { presetButton(presets[i]) }
                        else { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                    }
                }
            }
        }
        .opacity(enabled ? 1 : 0.55)
    }

    private func presetButton(_ name: String) -> some View {
        let on = music.isSelected(name)
        // «Настройка вручную» — редактируемый пресет «Музыки»: у выбранного — значок ползунков, повторное нажатие
        // открывает редактор полос (16.11: пользователь искал полосы именно там).
        let editId = music.editableId(name: name)
        return HStack(spacing: 4) {
            Text(name)
                .font(theme.font(11, on ? .bold : .semibold)).lineLimit(1).minimumScaleFactor(0.62)
            if on && editId != nil {
                Image(systemName: "slider.vertical.3").font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(theme.secondary)
            }
        }
            .foregroundStyle(on ? theme.primary : theme.secondary)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity).frame(height: 22)
            .background(Capsule().fill(on ? theme.accentColor.opacity(0.32) : theme.controlFillColor))
            .overlay(Capsule().strokeBorder(on ? theme.accentColor.opacity(0.9) : .clear, lineWidth: 1))
            .contentShape(Capsule())
            .onTapGesture { if on, let id = editId { music.editing = id } else { music.select(name) } }
            .contextMenu {
                if let id = editId { Button("Изменить полосы") { music.select(name); music.editing = id } }
            }
            .help(editId == nil ? "Пресет «\(name)» в Музыке"
                  : on ? "«\(name)» — нажмите ещё раз, чтобы поменять полосы" : "«\(name)» — пресет Музыки, полосы можно менять")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Пресет \(name)")
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : [.isButton])
            .accessibilityAction { music.select(name) }
    }

    private func note(_ text: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: systemImage).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.tertiary)
            Text(text).font(theme.font(11.5, .medium)).foregroundStyle(theme.tertiary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Спектр

    @ViewBuilder private func spectrumNote(_ state: EqualizerState) -> some View {
        switch state {
        case .needsPermission:
            HStack(spacing: 6) {
                Text("Нет доступа к звуку").font(theme.font(11, .semibold)).foregroundStyle(IslandPalette.warmText(theme))
                IslandButton("Разрешить", style: .accent, height: 22) { model.setLiveVisualizer(true) }
            }
            .fixedSize()
        case .off:
            IslandButton("Спектр по звуку", systemImage: "waveform", height: 22) { model.setLiveVisualizer(true) }
        case .noSignal:
            HStack(spacing: 6) {
                Text("Нет доступа к звуку").font(theme.font(11, .semibold)).foregroundStyle(IslandPalette.warmText(theme))
                IslandButton("Разрешить", style: .accent, height: 22) { model.setLiveVisualizer(true) }
            }
            .fixedSize()
        case .paused:
            Text("пауза").font(theme.font(11, .semibold)).foregroundStyle(theme.tertiary)
        case .silence:
            Text("тишина — ничего не играет").font(theme.font(11, .semibold)).foregroundStyle(theme.tertiary)
        case .live:
            Text("спектр по звуку · не записывается")
                .font(theme.font(11, .semibold)).foregroundStyle(theme.tertiary).lineLimit(1)
        }
    }
}

/// Крошечная АЧХ своего пресета в его кнопке.
struct EqualizerMiniCurve: View {
    let bands: [Double]
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            guard bands.count > 1 else { return }
            let pts = bands.enumerated().map { CGPoint(x: size.width * CGFloat($0.offset) / CGFloat(bands.count - 1),
                                                       y: CustomEQPreset.y(of: $0.element, height: size.height)) }
            var p = Path(); p.move(to: pts[0])
            for i in 1..<pts.count {
                let a = pts[i - 1], b = pts[i], mx = (a.x + b.x) / 2
                p.addCurve(to: b, control1: CGPoint(x: mx, y: a.y), control2: CGPoint(x: mx, y: b.y))
            }
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

extension MusicEqualizer {
    /// Пресеты «Музыки» в русской локали (как у пользователя 16.11) — для снимков «Настройки вручную».
    static let mockPresetsRu = ["Настройка вручную", "Акустическая", "Без коррекции", "Больше вокала", "Больше высоких частот",
                                "Больше низких частот", "Джаз", "Дип-хаус", "Классическая", "Латиноамериканская", "Лаунж",
                                "Малые динамики", "Меньше высоких частот", "Меньше низких частот", "Поп", "Речь",
                                "Ритм-энд-блюз", "Рок", "Танцевальная", "Тонкомпенсация", "Фортепиано", "Хип-хоп", "Электронная"]
    static let mockManualBands: [Double] = [0, 4, 3, 1.5, 0, -1, -1.5, 0, 2, 3.5, 4]
    /// Свои пресеты для снимков и самотеста.
    static let mockCustoms: [CustomEQPreset] = [
        CustomEQPreset(id: "mock-bass", name: "Ночной бас", preamp: -3, bands: [9, 7.5, 5, 2, 0, -1, 0, 1.5, 3, 2]),
        CustomEQPreset(id: "mock-voice", name: "Подкасты", preamp: 0, bands: [-6, -4, -1, 1, 3, 4.5, 4, 2, 0, -2]),
    ]

    /// Пресеты «Музыки» (как в macOS 15, англ.) — для снимков и самотеста.
    static let mockPresets = ["Acoustic", "Bass Booster", "Bass Reducer", "Classical", "Dance", "Deep", "Electronic",
                              "Flat", "Hip-Hop", "Jazz", "Late Night", "Latin", "Loudness", "Lounge", "Piano", "Pop",
                              "R&B", "Rock", "Small Speakers", "Spoken Word", "Treble Booster", "Treble Reducer",
                              "Vocal Booster", "Manual"]
}
