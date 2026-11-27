import AppKit
import IslandCore
import Foundation
import LyricsCore
import MusicKit
import SwiftUI
import WebKit

/// Подключение Apple Music для текстов (16.11). Путь 1 — системная учётка (вход в «Музыке»): MusicKit
/// `MusicAuthorization.request()` (одно системное «Разрешить») + `MusicUserTokenProvider().userToken(for:)` с developer
/// token веб-плеера (его LyricsCore добывает сам). Проверено 16.11 пробным .app с ad-hoc подписью, без аккаунта
/// разработчика: user token выдан, amp-api принял его как `media-user-token` (storefront 200, syllable-lyrics 200, TTML
/// с пословной разметкой). Токен перевыпускается сам, когда меняется developer token (после 401 LyricsCore берёт новый)
/// или ему больше 7 дней — `AppleMusicCredentialStore`. Путь 2 (запасной) — вход на music.apple.com в окне: окно с WKWebView на music.apple.com — пользователь входит САМ своим Apple ID на
/// странице Apple (приложение пароль не видит и не хранит). После входа из хранилища cookie окна берётся
/// `media-user-token` (домен `.music.apple.com`), сохраняется тем же путём, что и вставленный руками
/// (`LyricsService.setAppleToken` → `FileCredentialStore`/`SecretFile`, права 600), окно закрывается, отрицательный кеш
/// текстов сбрасывается и текущий трек ищется заново. У окна своё хранилище данных (`WKWebsiteDataStore(forIdentifier:)`),
/// не общий браузер; «Выйти» удаляет токен и это хранилище. Значение токена нигде не печатается.

/// Состояние подключения Apple Music (для настроек и острова).
enum AppleMusicStatus: Equatable, Sendable {
    /// Ещё не смотрели.
    case unknown
    case notConnected
    case checking
    /// Токен принят Apple (`/v1/me/storefront` ответил), `storefront` — страна подписки.
    case connected(storefront: String?)
    /// 401/403 и после свежего developer token: подписки нет или вход устарел.
    case needsSubscription
    /// Проверить не удалось (сеть, Apple не ответил) — токен сохранён, тексты попробуют сами.
    case unverified(String)

    var title: String {
        switch self {
        case .unknown, .checking: return "Проверяю…"
        case .notConnected: return "Не подключена"
        case .connected(let sf): return "Apple Music подключена" + (sf.map { " · \($0.uppercased())" } ?? "")
        case .needsSubscription: return "Нужна подписка Apple Music — или войдите заново"
        case .unverified(let why): return "Токен сохранён, проверить не удалось (\(why))"
        }
    }

    var isConnected: Bool { if case .connected = self { return true }; return false }
}

/// Чистая часть: разбор cookie, проверка токена запросом к amp-api. Без окна — для самотеста.
enum AppleMusicAuth {
    static let cookieName = "media-user-token"
    static let loginURL = URL(string: "https://music.apple.com/")!
    /// Своё хранилище данных окна входа (постоянное: повторный вход после истечения токена — без пароля).
    static let storeID = UUID(uuidString: "5E1A7D2C-6B8F-4C1E-9A3D-AB0C1D2E3F41")!
    /// Safari: без версии Safari в User-Agent веб-плеер может счесть WKWebView неподдерживаемым браузером.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"

    /// Домен cookie — music.apple.com или его поддомен (`.music.apple.com`), не «music.apple.com.чужой.сайт».
    static func isAppleMusicDomain(_ domain: String) -> Bool {
        let d = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return d == "music.apple.com" || d.hasSuffix(".music.apple.com")
    }

    /// `media-user-token` из cookie окна: нужное имя, домен Apple Music, не пусто, не просрочено. Несколько — самый
    /// долгоживущий. nil — пользователь ещё не вошёл.
    static func token(from cookies: [HTTPCookie], now: Date = Date()) -> String? {
        cookies
            .filter { $0.name == cookieName && isAppleMusicDomain($0.domain) }
            .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { ($0.expiresDate ?? .distantFuture) > now }
            .max { ($0.expiresDate ?? .distantFuture) < ($1.expiresDate ?? .distantFuture) }?
            .value
    }

    /// Проверка токена тем же запросом, что первым делает `AppleMusicProvider` (`GET amp-api /v1/me/storefront` с
    /// developer token веб-плеера и media-user-token). 401/403 — один раз с новым developer token, снова отказ — подписки нет.
    static func verify(token mut: String, http: HTTPClient, developerTokens: AppleDeveloperTokenProvider,
                       host: String = "https://amp-api.music.apple.com") async -> AppleMusicStatus {
        guard let url = URL(string: host + "/v1/me/storefront") else { return .unverified("адрес") }
        var refreshed = false
        while true {
            let dev: String
            do { dev = try await developerTokens.token(forceRefresh: refreshed) } catch {
                return .unverified("нет ключа веб-плеера Apple")
            }
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            for (k, v) in ["Authorization": "Bearer \(dev)", "media-user-token": mut, "Origin": "https://music.apple.com",
                           "Referer": "https://music.apple.com/", "User-Agent": userAgent, "Accept": "application/json"] {
                req.setValue(v, forHTTPHeaderField: k)
            }
            let resp: HTTPResponse
            do { resp = try await http.send(req) } catch { return .unverified("нет сети") }
            switch resp.status {
            case 200..<300:
                let obj = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any]
                let sf = ((obj?["data"] as? [[String: Any]])?.first?["id"] as? String)
                return .connected(storefront: sf)
            case 401, 403:
                if refreshed { return .needsSubscription }
                refreshed = true
                await developerTokens.invalidate()
            default:
                return .unverified("Apple ответил \(resp.status)")
            }
        }
    }
}

// MARK: - Путь 1: системная учётка Apple Music (MusicKit)

enum SystemAppleMusic {
    /// Уже спрашивали и пользователь отказал / запрещено политикой.
    static var isDenied: Bool { [.denied, .restricted].contains(MusicAuthorization.currentStatus) }

    /// Разрешение (первый раз — системное окно «SimpleIsland хочет доступ к Apple Music»).
    static func authorize() async -> MusicAuthorization.Status {
        let s = MusicAuthorization.currentStatus
        return s == .notDetermined ? await MusicAuthorization.request() : s
    }

    /// User token подписки для developer token веб-плеера (без окна, если разрешение уже дано).
    static func mint(developerToken: String, ignoreCache: Bool = false) async throws -> String {
        try await MusicUserTokenProvider().userToken(for: developerToken, options: ignoreCache ? [.ignoreCache] : [])
    }

    /// Отпечаток developer token (сам токен в метаданные не пишем).
    static func fingerprint(_ devToken: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in devToken.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}

/// Хранилище секретов текстов: обычный файл секретов (`base`) плюс самообновление токена, выданного системой. Если
/// токен из системной учётки (`markSystem`) и developer token сменился (LyricsCore после 401 берёт новый) или токену
/// больше `maxAge` — при чтении `.mediaUserToken` выпускается новый через MusicKit. Токен, вставленный руками или
/// взятый из окна входа, не трогается. Метаданные (источник, отпечаток developer token, время) — рядом в файле секретов.
actor AppleMusicCredentialStore: CredentialStore {
    typealias Minter = @Sendable (_ devToken: String, _ ignoreCache: Bool) async throws -> String
    static let metaService = "local.simpleisland.lyrics.meta"
    static let maxAge: TimeInterval = 7 * 86400

    private let base: CredentialStore
    private let meta: SecretFile
    private let minter: Minter
    private let now: @Sendable () -> Date
    /// Сколько раз выпускали (самотест).
    private(set) var mints = 0

    init(base: CredentialStore, meta: SecretFile = .shared,
         minter: @escaping Minter = { try await SystemAppleMusic.mint(developerToken: $0, ignoreCache: $1) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.base = base; self.meta = meta; self.minter = minter; self.now = now
    }

    private func m(_ k: String) -> String? { meta.value(service: Self.metaService, account: k) }
    private func setM(_ k: String, _ v: String?) { meta.set(v, service: Self.metaService, account: k) }

    var isSystem: Bool { m("source") == "system" }

    func value(for key: CredentialKey) async throws -> String? {
        let v = try await base.value(for: key)
        guard key == .mediaUserToken, isSystem, let dev = try await currentDeveloperToken() else { return v }
        let fp = SystemAppleMusic.fingerprint(dev)
        let at = m("mintedAt").flatMap(Double.init) ?? 0
        let stale = now().timeIntervalSince1970 - at > Self.maxAge
        if let v, !v.isEmpty, m("mintedWith") == fp, !stale { return v }
        guard let fresh = try? await minter(dev, stale), !fresh.isEmpty else { return v }
        mints += 1
        try await base.set(fresh, for: .mediaUserToken)
        setM("mintedWith", fp)
        setM("mintedAt", String(now().timeIntervalSince1970))
        return fresh
    }

    func set(_ value: String?, for key: CredentialKey) async throws {
        try await base.set(value, for: key)
        // Новый/удалённый токен пользователя — уже не «из системы», пока `markSystem` не скажет обратное.
        if key == .mediaUserToken { setM("source", nil); setM("mintedWith", nil); setM("mintedAt", nil) }
    }

    /// Токен в `base` выдан системой для этого developer token.
    func markSystem(developerToken: String) {
        setM("source", "system")
        setM("mintedWith", SystemAppleMusic.fingerprint(developerToken))
        setM("mintedAt", String(now().timeIntervalSince1970))
    }

    private func currentDeveloperToken() async throws -> String? {
        guard let json = try await base.value(for: .appleDeveloperToken), let d = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return obj["token"] as? String
    }
}

// MARK: - Сервис текстов: подключение и сброс отрицательного кеша (отдельно от LyricsService.swift — проще слияние)

extension LyricsService {
    /// Сохранить токен после входа и забыть «не найдено» — чтобы треки, у которых без Apple текста не было, спросили снова.
    func connectApple(token: String) async -> Bool {
        _ = purgeNegativeCache()
        return await setAppleToken(token)
    }

    /// Удалить из дискового кеша записи «не найдено» (`best` пуст). Возвращает, сколько удалено.
    @discardableResult
    nonisolated func purgeNegativeCache() -> Int {
        var n = 0
        for (url, _) in Self.files(cache.directory) where url.pathExtension == "json" {
            guard let d = try? Data(contentsOf: url),
                  let env = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let entry = env["entry"] as? [String: Any] else { continue }
            let best = entry["best"]
            if best == nil || best is NSNull { try? FileManager.default.removeItem(at: url); n += 1 }
        }
        return n
    }

    /// Проверить сохранённый токен (сеть: amp-api). Нет токена — `.notConnected`. Страна подписки запоминается.
    func verifyApple(http: HTTPClient? = nil) async -> AppleMusicStatus {
        guard let mut = try? await credentials.value(for: .mediaUserToken), !mut.isEmpty else { return .notConnected }
        let client = http ?? URLSessionHTTPClient(timeout: 10, retries: 1)
        let tokens = AppleDeveloperTokenProvider(http: client, store: credentials)
        let st = await AppleMusicAuth.verify(token: mut, http: client, developerTokens: tokens)
        if case .connected(let sf?) = st { try? await credentials.set(sf, for: .appleStorefront) }
        return st
    }
}

// MARK: - Состояние для интерфейса

/// Одно на процесс: состояние входа для настроек «Тексты» и кнопки в острове.
@MainActor
final class AppleMusicAccount: ObservableObject {
    static let shared = AppleMusicAccount()

    @Published private(set) var status: AppleMusicStatus = .unknown
    /// Токен сохранён (без сети). nil — ещё не смотрели.
    @Published private(set) var hasToken: Bool?
    /// Последнее сообщение после входа/выхода («Apple Music подключена», ошибка) — для настроек.
    @Published var message: String?

    private var login: AppleMusicLoginWindow?

    /// Только локально: есть ли токен (для кнопки в острове). Сеть не трогает.
    func refreshLocal(_ service: LyricsService) {
        guard hasToken == nil else { return }
        Task {
            let has = await service.hasAppleToken()
            hasToken = has
            if !has { status = .notConnected }
        }
    }

    /// Проверка с сетью (настройки открыты, кнопка «Проверить»).
    func verify(_ model: MediaModel) {
        let service = model.lyricsService
        status = .checking
        Task {
            let st = await service.verifyApple()
            status = st
            hasToken = st != .notConnected
        }
    }

    /// «Подключить Apple Music»: системная учётка (одно «Разрешить»); не вышло — окно входа на music.apple.com.
    func connectSystem(model: MediaModel, fallbackToWeb: Bool = true) {
        message = nil
        status = .checking
        Task {
            let service = model.lyricsService
            let auth = await SystemAppleMusic.authorize()
            guard auth == .authorized else {
                status = hasToken == true ? status : .notConnected
                message = "Нет доступа к Apple Music: Системные настройки → Конфиденциальность и безопасность → Медиа и Apple Music → SimpleIsland. Или войдите через сайт."
                if fallbackToWeb { openLogin(model: model) }
                return
            }
            let devTokens = AppleDeveloperTokenProvider(http: URLSessionHTTPClient(timeout: 12, retries: 1), store: service.credentials)
            guard let dev = try? await devTokens.token() else {
                status = .unverified("нет ключа веб-плеера Apple"); message = "Apple не ответил — проверьте сеть и попробуйте ещё раз."
                return
            }
            let user: String
            do { user = try await SystemAppleMusic.mint(developerToken: dev) } catch {
                status = .notConnected
                message = "Система не выдала ключ Apple Music (войдите в «Музыке» или через сайт)."
                if fallbackToWeb { openLogin(model: model) }
                return
            }
            await connect(token: user, model: model, systemDeveloperToken: dev)
        }
    }

    /// Окно входа. После входа — сохранить, сбросить отрицательный кеш, перезапросить текущий трек, проверить.
    func openLogin(model: MediaModel) {
        if let w = login { w.show(); return }
        message = nil
        let w = AppleMusicLoginWindow { [weak self, weak model] token in
            guard let self, let model else { return }
            self.login = nil
            guard let token else { return }   // закрыли без входа
            Task { await self.connect(token: token, model: model) }
        }
        login = w
        w.show()
    }

    /// Сохранить токен (тот же путь, что ручная вставка: файл секретов), забыть «не найдено», перезапросить текущий
    /// трек, проверить у Apple. `systemDeveloperToken` — токен выдан системой (будет перевыпускаться сам).
    func connect(token: String, model: MediaModel, systemDeveloperToken: String? = nil) async {
        let service = model.lyricsService
        status = .checking
        service.purgeNegativeCache()
        guard await model.setAppleToken(token) else {   // + сброс памяти и перезапрос текущего трека
            message = "Не удалось сохранить вход."; status = .notConnected; return
        }
        if let dev = systemDeveloperToken, let store = service.credentials as? AppleMusicCredentialStore {
            await store.markSystem(developerToken: dev)
        }
        hasToken = true
        let st = await service.verifyApple()
        status = st
        switch st {
        case .connected: message = "Apple Music подключена"
        case .needsSubscription:
            // Токен Apple не принимает — не держим его: иначе каждый трек ходил бы в Apple впустую.
            _ = await model.setAppleToken(nil)
            hasToken = false
            message = "Apple не принял вход: нужна подписка Apple Music. Войдите тем Apple ID, где она есть."
        default: message = nil
        }
    }

    /// Выйти: токен (и developer token, страна) — из файла секретов, данные окна входа — вон.
    func signOut(model: MediaModel) async {
        login?.close(); login = nil
        _ = await model.setAppleToken(nil)
        await Self.removeLoginData()
        hasToken = false
        status = .notConnected
        message = "Вы вышли из Apple Music."
    }

    static func removeLoginData() async {
        let store = WKWebsiteDataStore(forIdentifier: AppleMusicAuth.storeID)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        try? await WKWebsiteDataStore.remove(forIdentifier: AppleMusicAuth.storeID)
    }
}

// MARK: - Окно входа

/// Окно с music.apple.com. Ждёт cookie `media-user-token` в своём хранилище и отдаёт его один раз (`onFinish(token)`);
/// закрыли без входа — `onFinish(nil)`.
@MainActor
final class AppleMusicLoginWindow: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    private let window: NSWindow
    private let webView: WKWebView
    private let store: WKWebsiteDataStore
    private var onFinish: ((String?) -> Void)?
    /// Всплывающие окна страницы входа (`window.open`).
    private var popups: [NSWindow] = []

    init(onFinish: @escaping (String?) -> Void) {
        self.onFinish = onFinish
        store = WKWebsiteDataStore(forIdentifier: AppleMusicAuth.storeID)
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = store
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.customUserAgent = AppleMusicAuth.userAgent
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Войти в Apple Music"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let header = NSHostingView(rootView: LoginHeader())
        let stack = NSStackView(views: [header, webView])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        header.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            webView.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        window.contentView = stack
        window.center()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        store.httpCookieStore.add(self)
        webView.load(URLRequest(url: AppleMusicAuth.loginURL))
        checkCookies()      // уже входили раньше (данные окна сохранены) — токен есть сразу
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.close() }

    private func finish(_ token: String?) {
        guard let f = onFinish else { return }
        onFinish = nil
        store.httpCookieStore.remove(self)
        webView.stopLoading()
        for p in popups { p.close() }
        popups = []
        if window.isVisible { window.close() }
        f(token)
    }

    private func checkCookies() {
        store.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let t = AppleMusicAuth.token(from: cookies) else { return }
            Task { @MainActor in self?.finish(t) }
        }
    }

    // MARK: делегаты

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in self.checkCookies() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { checkCookies() }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === window { finish(nil) }
        else if let w = notification.object as? NSWindow { popups.removeAll { $0 === w } }
    }

    /// `window.open` страницы входа Apple — в отдельном окне с той же конфигурацией (то же хранилище cookie).
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let child = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 640), configuration: configuration)
        child.customUserAgent = AppleMusicAuth.userAgent
        child.uiDelegate = self
        child.navigationDelegate = self
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Apple ID"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = child
        w.center()
        w.makeKeyAndOrderFront(nil)
        popups.append(w)
        return child
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let w = popups.first(where: { $0.contentView === webView }) { w.close() }
    }
}

/// Подсказка над страницей Apple.
private struct LoginHeader: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(.secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Нажмите «Войти» вверху справа и войдите своим Apple ID с подпиской Apple Music.")
                    .font(.callout.weight(.semibold))
                Text("Это страница Apple: пароль вводится только ей, SimpleIsland его не видит и не хранит. После входа окно закроется само — остров возьмёт из этого окна только ключ для текстов песен.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
