import IslandCore

/// Что озвучивает VoiceOver про остров: один элемент-контейнер «SimpleIsland: <что показывает>» (грабли D10).
/// Чистые функции от модели — проверяются самотестом `--selftest-core a11y`.
@MainActor
enum IslandAccessibility {
    static func label(_ model: IslandModel) -> String {
        let env = model.env
        let what: String
        switch model.presentation {
        case .idle:
            what = env.activities.idleDot != nil ? "покой, есть статус" : "покой"
        case .compact:
            let shown = compactShown(model)
            var parts = shown.ears.map { activityText($0, env: env) }
            if let b = shown.secondary { parts.append("ещё: " + activityText(b, env: env)) }
            what = parts.isEmpty ? "компакт" : parts.joined(separator: "; ")
        case .hud:
            what = env.hud.current?.spokenDescription ?? "вспышка"
        case .notification:
            what = env.notifications.current?.spokenDescription ?? "уведомление"
        case .expanded:
            what = "раскрыт, вкладка \(model.currentTab?.title ?? "нет")"
        }
        return "SimpleIsland: \(what)"
    }

    /// Что видно в компакте: активности ушей (одна или две разные) и значок второй активности в ухе. Источник для
    /// озвучки — тот же, что у рисующей вьюхи: уши — `compactEars(left:right:)` по назначениям из настроек
    /// (`SettingsEars.swift`), значок — `secondaryActivity(left:right:)`. Иначе VoiceOver назвал бы не то, что на экране.
    static func compactShown(_ model: IslandModel) -> (ears: [IslandActivity], secondary: IslandActivity?) {
        let a = model.env.activities
        let data = model.env.settings.data
        let left = data.leftEarModule, right = data.rightEarModule
        var ears: [IslandActivity] = []
        if let e = a.compactEars(left: left, right: right) {
            for id in [e.leadingId, e.trailingId] where !ears.contains(where: { $0.id == id }) {
                if let act = a.activities.first(where: { $0.id == id }) { ears.append(act) }
            }
        }
        return (ears, model.secondaryActivity)
    }

    static func hint(_ model: IslandModel) -> String {
        switch model.presentation {
        case .expanded: return "Свайп вверх или действие «Свернуть» — свернуть"
        case .notification: return "Нажмите, чтобы открыть"
        default: return model.env.enabledTabModules.isEmpty ? "" : "Нажмите, чтобы раскрыть"
        }
    }

    static func activityText(_ a: IslandActivity, env: AppEnvironment) -> String {
        a.accessibilityLabel ?? env.module(id: a.moduleId)?.title ?? a.moduleId
    }
}
