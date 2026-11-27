import AppKit
import Combine
import SwiftUI
import IslandCore

/// Окна настроек и онбординга, горячая клавиша. Один на процесс; AppDelegate зовёт `start` при запуске.
@MainActor
final class SettingsWindows: NSObject, NSWindowDelegate {
    static let shared = SettingsWindows()

    let nav = SettingsNavigation()
    private(set) var env: AppEnvironment?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var bag = Set<AnyCancellable>()

    /// Запуск: горячая клавиша (раскрыть/свернуть), внешний вид окон под тему, онбординг при первом запуске.
    func start(env: AppEnvironment, toggleIsland: @escaping () -> Void) {
        self.env = env
        GlobalHotKey.shared.action = toggleIsland
        env.settings.$data
            .map { [$0.toggleHotKeyEnabled ? 1 : 0, Int($0.toggleHotKey.keyCode), Int($0.toggleHotKey.modifiers)] }
            .removeDuplicates()
            .sink { _ in DispatchQueue.main.async { MainActor.assumeIsolated { SettingsWindows.shared.applyHotKey() } } }
            .store(in: &bag)
        env.themes.$current
            .sink { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.styleWindows() } } }
            .store(in: &bag)
        // SIMPLEISLAND_NO_ONBOARDING=1 — не открывать онбординг сам (замеры энергии в покое без правки settings.json).
        if !env.settings.data.onboardingCompleted, ProcessInfo.processInfo.environment["SIMPLEISLAND_NO_ONBOARDING"] != "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated { self.showOnboarding() } }
        }
    }

    /// Регистрация горячей клавиши по настройкам (выключена — снять).
    func applyHotKey() {
        guard let d = env?.settings.data else { return }
        GlobalHotKey.shared.register(d.toggleHotKeyEnabled ? d.toggleHotKey : nil)
    }

    // MARK: Настройки

    func showSettings(section: SettingsSection? = nil) {
        guard let env else { return }
        if let section { nav.section = section }
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "SimpleIsland — настройки"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 1020, height: 640)
            w.setContentSize(NSSize(width: 1240, height: 800))
            w.center()
            w.setFrameAutosaveName("SimpleIslandSettings")
            w.delegate = self
            settingsWindow = w
        }
        // Содержимое — заново на каждое открытие: при закрытии оно освобождается (превью с живыми вкладками модулей,
        // его подписки и анимации не должны жить при закрытом окне — SwiftUI не зовёт onDisappear у скрытого окна).
        if let w = settingsWindow, w.contentViewController == nil {
            let frame = w.frame
            // Под прозрачный заголовок (fullSizeContentView): без ignoresSafeArea на macOS 27 сверху белая полоса (25.11).
            let host = NSHostingController(rootView: SettingsRootView(env: env, nav: nav).ignoresSafeArea())
            host.sizingOptions = []   // окно настроек меняет размер пользователь, не содержимое
            w.contentViewController = host
            w.setFrame(frame, display: false)
        }
        GlobalHotKey.shared.refreshSystemConflict()
        styleWindows()
        PermissionCenter.shared.refresh()
        LoginItem.shared.refresh()
        Self.bringToFront(settingsWindow)
    }

    // MARK: Онбординг

    func showOnboarding() {
        guard let env else { return }
        if onboardingWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Добро пожаловать в SimpleIsland"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.isMovableByWindowBackground = true
            w.backgroundColor = .black
            w.appearance = NSAppearance(named: .darkAqua)
            w.delegate = self
            onboardingWindow = w
        }
        // Каждый показ — с первого шага; вьюха создаётся заново (её анимация живёт, только пока окно открыто).
        // Размер окна фиксированный: без `sizingOptions = []` хост подгонял окно под содержимое — на macOS 27 после
        // `ignoresSafeArea` окно вырастало ниже экрана, кнопки «Далее/Назад» уезжали за край (27.11).
        let host = NSHostingController(rootView: OnboardingView(env: env) { [weak self] in
            self?.finishOnboarding()
        }.frame(width: 820, height: 600).ignoresSafeArea())
        host.sizingOptions = []
        onboardingWindow?.contentViewController = host
        onboardingWindow?.setContentSize(NSSize(width: 820, height: 600))
        onboardingWindow?.center()
        PermissionCenter.shared.refresh()
        Self.bringToFront(onboardingWindow)
    }

    /// Окно — поверх всех, с фокусом (25.11, macOS 27: `NSApp.activate()` у приложения без Dock не выводило окно —
    /// обучение открывалось позади окон других приложений).
    static func bringToFront(_ w: NSWindow?) {
        guard let w else { return }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }

    private func finishOnboarding() {
        env?.settings.data.onboardingCompleted = true
        onboardingWindow?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if w === onboardingWindow {
            // Закрыли крестиком — тоже «пройден»: всё необязательно, повторно — из меню.
            env?.settings.data.onboardingCompleted = true
            DispatchQueue.main.async { MainActor.assumeIsolated { w.contentViewController = nil } }
        } else if w === settingsWindow {
            // Окно остаётся (место и размер), содержимое освобождается — см. showSettings.
            DispatchQueue.main.async { MainActor.assumeIsolated { if !w.isVisible { w.contentViewController = nil } } }
        }
    }

    /// Внешний вид окна настроек под тему: светлая тема — светлое окно (системные попапы и светофор тоже).
    private func styleWindows() {
        guard let env, let w = settingsWindow else { return }
        let theme = env.settings.data.applying(to: env.themes.current)
        w.appearance = NSAppearance(named: theme.isLight ? .aqua : .darkAqua)
        w.backgroundColor = NSColor(SettingsPalette(theme: theme).window)
    }
}
