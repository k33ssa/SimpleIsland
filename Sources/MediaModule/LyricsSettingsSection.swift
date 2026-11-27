import SwiftUI

/// «Медиа» → «Тексты»: источники каскада с переключателями, подключение Apple Music (системная учётка → вход на сайте →
/// токен руками; хранится в файле секретов острова), кеш.
struct LyricsSettingsSection: View {
    @ObservedObject var model: MediaModel
    @ObservedObject private var apple = AppleMusicAccount.shared
    @ObservedObject private var yandex = YandexMusicAccount.shared
    private var hasToken: Bool { apple.hasToken == true }
    @State private var askToken = false
    @State private var tokenDraft = ""
    @State private var tokenError: String?
    @State private var cacheSize: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Тексты").font(.headline)
            Toggle("Искать текст песни (нужна сеть)", isOn: $model.prefs.lyricsEnabled)
            Toggle("…и для браузеров и других плееров", isOn: $model.prefs.lyricsAnyApp)
                .disabled(!model.prefs.lyricsEnabled)
            Text("Источники опрашиваются по порядку (стрелки справа меняют его); пословный текст важнее построчного, при равной синхронизации — тот, что выше. Уходят только исполнитель, название и длительность. По умолчанию — только для Музыки и Spotify: у браузеров это часто название видео.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let order = model.prefs.lyricsOrder
            ForEach(Array(order.enumerated()), id: \.element) { i, kind in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top) {
                        Toggle(isOn: binding(kind)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(kind.title)
                                Text(kind == .apple && !hasToken ? "Нужна подписка Apple Music — подключите её ниже"
                                     : kind == .yandex && yandex.hasToken != true ? "Построчный текст из каталога Яндекса — войдите ниже" : kind.note)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        Button { move(kind, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless).disabled(i == 0)
                            .help("Спрашивать раньше").accessibilityLabel("\(kind.title): выше")
                        Button { move(kind, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless).disabled(i == order.count - 1)
                            .help("Спрашивать позже").accessibilityLabel("\(kind.title): ниже")
                    }
                    if kind == .apple { appleRow }
                    if kind == .yandex { yandexRow }
                }
                .disabled(!model.prefs.lyricsEnabled)
            }
            Divider()
            HStack {
                Text("Кеш текстов песен")
                Spacer()
                Text(cacheSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "…")
                    .foregroundStyle(.secondary).monospacedDigit()
                Button("Очистить кеш") {
                    Task { await model.clearCaches(); cacheSize = await model.cacheSize() }
                }
            }
            Text("Только тексты для офлайна: не больше 200 песен и 5 МБ, не дольше 30 дней. Обложки и превью на диск не пишутся.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task {
            cacheSize = await model.cacheSize()
            // Проверка у Apple (сеть) — только если токен есть; нет — без запросов.
            if await model.hasAppleToken() { apple.verify(model) } else { apple.refreshLocal(model.lyricsService) }
            yandex.refreshLocal()
            if yandex.hasToken == true { yandex.verify() }
        }
        .sheet(isPresented: $askToken) { tokenSheet }
    }

    @ViewBuilder private var appleRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if hasToken {
                HStack(spacing: 8) {
                    Label(apple.status.title, systemImage: apple.status.isConnected ? "checkmark.circle.fill"
                          : (apple.status == .needsSubscription ? "exclamationmark.triangle.fill" : "music.note"))
                        .font(.callout)
                        .foregroundStyle(apple.status.isConnected ? Color.green
                                         : (apple.status == .needsSubscription ? Color.orange : Color.secondary))
                    Spacer()
                    Button("Проверить") { apple.verify(model) }.disabled(apple.status == .checking)
                    Button("Выйти", role: .destructive) { Task { await apple.signOut(model: model) } }
                }
            } else {
                HStack(spacing: 8) {
                    Button("Подключить Apple Music") { apple.connectSystem(model: model) }
                        .buttonStyle(.borderedProminent)
                        .disabled(apple.status == .checking)
                    Button("Войти через сайт…") { apple.openLogin(model: model) }
                    Button("Токен вручную…") { tokenDraft = ""; tokenError = nil; askToken = true }
                        .buttonStyle(.link)
                }
                Text("Берёт ключ подписки из вашего входа в «Музыке» (macOS спросит разрешение один раз). Не вышло — вход на music.apple.com в окне: пароль вводится только Apple, остров его не видит.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let m = apple.message {
                Text(m).font(.caption).foregroundStyle(apple.status.isConnected ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 2)
    }

    @ViewBuilder private var yandexRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if yandex.hasToken == true {
                HStack(spacing: 8) {
                    Label(yandex.status.title, systemImage: yandex.status.isConnected ? "checkmark.circle.fill"
                          : (yandex.status == .invalid ? "exclamationmark.triangle.fill" : "music.note"))
                        .font(.callout)
                        .foregroundStyle(yandex.status.isConnected ? Color.green
                                         : (yandex.status == .invalid ? Color.orange : Color.secondary))
                    Spacer()
                    Button("Проверить") { yandex.verify() }.disabled(yandex.status == .checking)
                    if yandex.status == .invalid { Button("Войти заново") { yandex.openLogin(model: model) } }
                    Button("Выйти", role: .destructive) { Task { await yandex.signOut(model: model) } }
                }
            } else {
                Button("Подключить Яндекс Музыку") { yandex.openLogin(model: model) }
                    .buttonStyle(.borderedProminent)
                    .disabled(yandex.status == .checking)
                Text("Вход на странице Яндекса в отдельном окне: пароль вводится только Яндексу, остров его не видит. Сохраняется только ключ для текстов — в файле секретов на этом Mac.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let m = yandex.message {
                Text(m).font(.caption).foregroundStyle(yandex.status.isConnected ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 2)
    }

    private var tokenSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Токен подписки Apple Music").font(.headline)
            Text("""
            Это cookie «media-user-token» вашего входа на music.apple.com. Где взять: откройте music.apple.com в браузере и войдите, \
            затем Инструменты разработчика (Safari: «Разработка» → «Показать веб-инспектор»; Chrome: ⌥⌘I) → Хранилище / Application → \
            Cookies → music.apple.com → значение «media-user-token».
            """)
            .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("Токен даёт доступ к вашей подписке: он хранится только в файле секретов острова на этом Mac (доступ — только у вашей учётной записи), никуда кроме Apple не отправляется и не попадает в журналы. Срок жизни — месяцы; если Apple его отвергнет, тексты пойдут из других источников.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("media-user-token", text: $tokenDraft)
                .textFieldStyle(.roundedBorder)
            if let e = tokenError { Text(e).font(.callout).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Отмена") { askToken = false }.keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    let t = tokenDraft
                    Task {
                        await apple.connect(token: t, model: model)
                        if apple.hasToken == true { askToken = false } else {
                            tokenError = apple.message ?? "Не удалось сохранить токен."
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).count < 20)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    /// Сдвинуть источник в порядке опроса; порядок по умолчанию не сохраняем (новые источники встанут на свои места).
    private func move(_ kind: LyricsSourceKind, by d: Int) {
        var o = model.prefs.lyricsOrder
        guard let i = o.firstIndex(of: kind), o.indices.contains(i + d) else { return }
        o.swapAt(i, i + d)
        model.prefs.lyricsSourceOrder = o == LyricsSourceKind.allCases ? [] : o.map(\.rawValue)
    }

    private func binding(_ kind: LyricsSourceKind) -> Binding<Bool> {
        Binding(get: { !model.prefs.lyricsSourcesOff.contains(kind.rawValue) },
                set: { on in
                    var off = Set(model.prefs.lyricsSourcesOff)
                    if on { off.remove(kind.rawValue) } else { off.insert(kind.rawValue) }
                    model.prefs.lyricsSourcesOff = LyricsSourceKind.allCases.map(\.rawValue).filter(off.contains)
                })
    }
}
