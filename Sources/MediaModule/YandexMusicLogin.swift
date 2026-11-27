import AppKit
import Foundation
import IslandCore
import LyricsCore
import SwiftUI
import WebKit

/// Подключение Яндекс Музыки для текстов (21.11). Окно с WKWebView (своё хранилище данных, не общий браузер) открывает
/// OAuth Яндекса — implicit flow `oauth.yandex.ru/authorize?response_type=token&client_id=<приложение Яндекс Музыки>`
/// (тот же client_id, что у открытых клиентов: `_DEFAULT_CLIENT_ID` в MarshalX/yandex-music-api, 21.11). Пользователь
/// входит САМ на странице Яндекса — пароль приложение не видит. После входа Яндекс уводит на адрес приложения с
/// `#access_token=…` во фрагменте: забираем его из URL навигации (переход отменяем), сохраняем в файл секретов
/// (`YandexMusicToken`), окно закрываем, кеш «без синхронизации» сбрасываем, текущий трек ищем заново. Проверка —
/// `GET /account/status` (у вошедшего есть `account.uid`). «Выйти» — удалить токен и данные окна.

enum YandexMusicStatus: Equatable, Sendable {
    case unknown
    case notConnected
    case checking
    case connected(login: String?, plus: Bool?)
    /// Яндекс не принял токен (401) — войти заново.
    case invalid
    case unverified(String)

    var title: String {
        switch self {
        case .unknown, .checking: return "Проверяю…"
        case .notConnected: return "Не подключена"
        case .connected(let login, let plus):
            return "Яндекс Музыка подключена" + (login.map { " · \($0)" } ?? "") + (plus == false ? " · без Плюса" : "")
        case .invalid: return "Вход устарел — войдите заново"
        case .unverified(let why): return "Вход сохранён, проверить не удалось (\(why))"
        }
    }

    var isConnected: Bool { if case .connected = self { return true }; return false }
}

/// Чистая часть: адрес входа, разбор редиректа с токеном, проверка токена. Без окна — для самотеста.
enum YandexMusicAuth {
    /// client_id приложения Яндекс Музыки (Android), как у открытых клиентов.
    static let clientID = "23cabbbdc6cd418abb4b39c32c41195d"
    static var authorizeURL: URL {
        URL(string: "https://oauth.yandex.ru/authorize?response_type=token&client_id=\(clientID)")!
    }
    /// Своё хранилище данных окна входа (постоянное: повторный вход — без пароля, пока Яндекс помнит сессию).
    static let storeID = UUID(uuidString: "7A3B9C1D-2E4F-4A6B-8C0D-1E2F3A4B5C61")!
    static let userAgent = AppleMusicAuth.userAgent

    enum Redirect: Equatable {
        case token(String)
        case error(String)
    }

    /// Домен Яндекса: `yandex.<зона>` или его поддомен (не «yandex.ru.чужой.сайт», не «notyandex.ru»).
    static func isYandexHost(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let zones = ["ru", "com", "by", "kz", "uz", "com.tr", "com.am", "com.ge", "az", "co.il", "ee", "lv", "lt", "md", "tj", "tm", "fr"]
        return zones.contains { z in h == "yandex.\(z)" || h.hasSuffix(".yandex.\(z)") }
    }

    /// Токен (или отказ) из адреса после входа: `…#access_token=…&token_type=bearer&expires_in=…`. Адрес — домен
    /// Яндекса по https или своя схема приложения (не http-сайт). nil — это ещё не редирект с результатом.
    static func parseRedirect(_ url: URL) -> Redirect? {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "http" { return nil }
        if scheme == "https" { guard let h = url.host, isYandexHost(h) else { return nil } }
        guard let frag = url.fragment ?? url.query, !frag.isEmpty else { return nil }
        var c = URLComponents()
        c.percentEncodedQuery = frag
        var items: [String: String] = [:]
        for i in c.queryItems ?? [] { items[i.name] = i.value ?? "" }
        if let t = items["access_token"]?.trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 10 { return .token(t) }
        if let e = items["error"], !e.isEmpty { return .error(items["error_description"] ?? e) }
        return nil
    }

    /// Проверка токена: `GET /account/status` с `Authorization: OAuth …`. 200 и `account.uid` — вошли; 401 — нет.
    static func verify(token: String, http: HTTPClient, host: String = "https://api.music.yandex.net") async -> YandexMusicStatus {
        guard let url = URL(string: host + "/account/status") else { return .unverified("адрес") }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(YandexMusicLyricsProvider.clientHeader, forHTTPHeaderField: "X-Yandex-Music-Client")
        req.setValue("OAuth " + token, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let r: HTTPResponse
        do { r = try await http.send(req) } catch { return .unverified("нет сети") }
        switch r.status {
        case 200: return parseStatus(r.data)
        case 401, 403: return .invalid
        default: return .unverified("Яндекс ответил \(r.status)")
        }
    }

    static func parseStatus(_ data: Data) -> YandexMusicStatus {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let res = obj["result"] as? [String: Any], let acc = res["account"] as? [String: Any] else {
            return .unverified("непонятный ответ")
        }
        guard acc["uid"] != nil else { return .invalid }       // без входа Яндекс отвечает тоже 200, но без uid
        let login = (acc["login"] as? String) ?? (acc["displayName"] as? String)
        let plus = (res["plus"] as? [String: Any])?["hasPlus"] as? Bool
        return .connected(login: login, plus: plus)
    }
}

// MARK: - Сервис текстов

extension LyricsService {
    /// Удалить из дискового кеша записи без синхронизации: «не найдено» и простой текст. Новый источник (вход в Яндекс)
    /// может дать построчный там, где раньше был только простой у Deezer. Возвращает, сколько удалено.
    @discardableResult
    nonisolated func purgeUnsyncedCache() -> Int {
        var n = 0
        for (url, _) in Self.files(cache.directory) where url.pathExtension == "json" {
            guard let d = try? Data(contentsOf: url),
                  let env = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let entry = env["entry"] as? [String: Any] else { continue }
            let best = entry["best"] as? [String: Any]
            if best == nil || (best?["syncType"] as? String) == SyncType.none.rawValue {
                try? FileManager.default.removeItem(at: url); n += 1
            }
        }
        return n
    }
}

// MARK: - Состояние для интерфейса

@MainActor
final class YandexMusicAccount: ObservableObject {
    static let shared = YandexMusicAccount()

    @Published private(set) var status: YandexMusicStatus = .unknown
    @Published private(set) var hasToken: Bool?
    @Published var message: String?

    var token = YandexMusicToken.shared
    private var login: YandexMusicLoginWindow?

    func refreshLocal() {
        let has = token.current() != nil
        hasToken = has
        if !has { status = .notConnected }
    }

    func verify() {
        guard let t = token.current() else { hasToken = false; status = .notConnected; return }
        status = .checking
        Task {
            let st = await YandexMusicAuth.verify(token: t, http: URLSessionHTTPClient(timeout: 10, retries: 1))
            status = st
            hasToken = true
        }
    }

    /// «Подключить Яндекс Музыку»: окно входа Яндекса.
    func openLogin(model: MediaModel) {
        if let w = login { w.show(); return }
        message = nil
        let w = YandexMusicLoginWindow { [weak self, weak model] result in
            guard let self, let model else { return }
            self.login = nil
            switch result {
            case .token(let t): Task { await self.connect(token: t, model: model) }
            case .error(let e): self.message = "Яндекс не выдал доступ: \(e)"
            case nil: break       // закрыли без входа
            }
        }
        login = w
        w.show()
    }

    /// Сохранить токен, проверить у Яндекса, сбросить кеш «без синхронизации», перезапросить текущий трек.
    func connect(token t: String, model: MediaModel) async {
        status = .checking
        token.set(t)
        hasToken = true
        let st = await YandexMusicAuth.verify(token: t, http: URLSessionHTTPClient(timeout: 10, retries: 1))
        status = st
        if st == .invalid {
            token.set(nil)
            hasToken = false
            message = "Яндекс не принял вход — попробуйте ещё раз."
        } else {
            message = st.isConnected ? "Яндекс Музыка подключена" : nil
        }
        await model.lyricsAccountChanged()
    }

    func signOut(model: MediaModel) async {
        login?.close(); login = nil
        token.set(nil)
        await YandexGate.shared.reset()
        await Self.removeLoginData()
        hasToken = false
        status = .notConnected
        message = "Вы вышли из Яндекс Музыки."
        await model.lyricsAccountChanged()
    }

    static func removeLoginData() async {
        let store = WKWebsiteDataStore(forIdentifier: YandexMusicAuth.storeID)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        try? await WKWebsiteDataStore.remove(forIdentifier: YandexMusicAuth.storeID)
    }
}

// MARK: - Окно входа

/// Окно с OAuth Яндекса. Ловит редирект с `#access_token` (в любом переходе: решение о навигации, серверный
/// редирект, смена адреса) и отдаёт результат один раз; закрыли без входа — `nil`.
@MainActor
final class YandexMusicLoginWindow: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private let window: NSWindow
    private let webView: WKWebView
    private var onFinish: ((YandexMusicAuth.Redirect?) -> Void)?
    private var urlObservation: NSKeyValueObservation?

    init(onFinish: @escaping (YandexMusicAuth.Redirect?) -> Void) {
        self.onFinish = onFinish
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = WKWebsiteDataStore(forIdentifier: YandexMusicAuth.storeID)
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.customUserAgent = YandexMusicAuth.userAgent
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Войти в Яндекс Музыку"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let header = NSHostingView(rootView: YandexLoginHeader())
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
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
            MainActor.assumeIsolated { if let u = wv.url { self?.inspect(u) } }
        }
        webView.load(URLRequest(url: YandexMusicAuth.authorizeURL))
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.close() }

    /// true — адрес с результатом входа (переход дальше не нужен).
    @discardableResult
    private func inspect(_ url: URL) -> Bool {
        guard let r = YandexMusicAuth.parseRedirect(url) else { return false }
        finish(r)
        return true
    }

    private func finish(_ r: YandexMusicAuth.Redirect?) {
        guard let f = onFinish else { return }
        onFinish = nil
        urlObservation = nil
        webView.stopLoading()
        if window.isVisible { window.close() }
        f(r)
    }

    // MARK: делегаты

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if let u = navigationAction.request.url, inspect(u) { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        if let u = webView.url { inspect(u) }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { if let u = webView.url { inspect(u) } }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { if let u = webView.url { inspect(u) } }

    /// Своя схема приложения в редиректе («не умею открыть») — тоже результат.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if let s = (error as NSError).userInfo[NSURLErrorFailingURLStringErrorKey] as? String, let u = URL(string: s) { inspect(u) }
    }

    /// `window.open` (вход через соцсети) — в этом же окне.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = navigationAction.request.url, !inspect(u) { webView.load(navigationAction.request) }
        return nil
    }

    func windowWillClose(_ notification: Notification) { finish(nil) }
}

private struct YandexLoginHeader: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(.secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Войдите в свой Яндекс ID и разрешите доступ приложению Яндекс Музыки.")
                    .font(.callout.weight(.semibold))
                Text("Это страница Яндекса: пароль вводится только ей, SimpleIsland его не видит и не хранит. После входа окно закроется само — остров возьмёт только ключ для текстов песен.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
