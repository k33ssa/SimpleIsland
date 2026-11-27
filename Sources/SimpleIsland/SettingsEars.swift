import SwiftUI
import IslandCore

/// Назначение модулей в уши компакта (Настройки → Раскладка): левое ухо берёт `leading` активности
/// своего модуля, правое — `trailing`. Нет назначения или у модуля сейчас нет активности — ухо как у главной.
struct CompactEars {
    var leading: AnyView
    var trailing: AnyView
    /// Ширина каждого уха — по самой широкой из участвующих активностей.
    var sideWidth: CGFloat
    /// Чьи части показаны: id активностей (для `.id` вьюхи и для самотестов).
    var leadingId: String
    var trailingId: String
    var id: String { leadingId + "|" + trailingId }
}

@MainActor
extension ActivityCenter {
    /// Самая важная активность модуля (в порядке `sorted`).
    func topActivity(moduleId: String) -> IslandActivity? {
        sorted.first { $0.moduleId == moduleId }
    }

    /// Уши компакта с учётом назначений. nil — активностей нет.
    func compactEars(left: String?, right: String?) -> CompactEars? {
        guard let p = primary else { return nil }
        let l = left.flatMap { topActivity(moduleId: $0) } ?? p
        let r = right.flatMap { topActivity(moduleId: $0) } ?? p
        return CompactEars(leading: l.leading, trailing: r.trailing,
                           sideWidth: max(l.sideWidth, r.sideWidth), leadingId: l.id, trailingId: r.id)
    }

    /// Ширина уха компакта с учётом назначений (+ место под значок второй активности, если он есть).
    func compactSideWidth(left: String?, right: String?) -> CGFloat? {
        guard let w = compactEars(left: left, right: right)?.sideWidth else { return nil }
        return w + (secondaryActivity(left: left, right: right) != nil ? SecondaryMark.width : 0)
    }

    /// Вторая активность — маленьким значком ВНУТРИ правого уха (UX 15.11: «не надо выносить за остров ничего»;
    /// раньше была «капля» снаружи справа). Это самая важная активность, которой нет в ушах, — но только если она
    /// несёт информацию: фон (музыка, priority ≤ 0) значком не показываем, он вернётся в уши сам, когда главная уйдёт.
    /// Исключение — главная: оба уха отданы другому модулю, тогда она видна хотя бы значком.
    func secondaryActivity(left: String?, right: String?) -> IslandActivity? {
        guard let ears = compactEars(left: left, right: right) else { return nil }
        let shown: Set<String> = [ears.leadingId, ears.trailingId]
        let main = primary?.id
        return sorted.first { !shown.contains($0.id) && ($0.priority > 0 || $0.id == main) }
    }

    /// «Хозяин» компакта — чьё свечение и чья вкладка по клику: главная активность, если она видна в ушах,
    /// иначе активность левого уха. Без назначений — главная (как раньше).
    func compactOwner(left: String?, right: String?) -> IslandActivity? {
        guard let ears = compactEars(left: left, right: right) else { return nil }
        if let p = primary, p.id == ears.leadingId || p.id == ears.trailingId { return p }
        return activities.first { $0.id == ears.leadingId } ?? primary
    }

    /// Свечение компакта по «хозяину» (см. `compactOwner`).
    func compactGlow(left: String?, right: String?) -> [Color]? {
        guard let o = compactOwner(left: left, right: right) else { return nil }
        return o.glowColors ?? ambientGlows[o.moduleId]
    }

    /// Клик по значку второй активности: поднять её в уши. true — она теперь в ушах; false — уши заняты
    /// назначенными модулями и поднять некуда (закрепление не меняется) — тогда вызывающий раскрывает её вкладку.
    @discardableResult
    func raiseSecondary(_ a: IslandActivity, left: String?, right: String?) -> Bool {
        let before = pinnedPrimaryId
        pin(id: a.id)
        if let ears = compactEars(left: left, right: right), ears.leadingId == a.id || ears.trailingId == a.id { return true }
        pin(id: before)
        return false
    }
}

extension SettingsData {
    /// Уши для текущих настроек.
    @MainActor func compactEars(in activities: ActivityCenter) -> CompactEars? {
        activities.compactEars(left: leftEarModule, right: rightEarModule)
    }
    @MainActor func compactOwner(in activities: ActivityCenter) -> IslandActivity? {
        activities.compactOwner(left: leftEarModule, right: rightEarModule)
    }
    @MainActor func compactGlow(in activities: ActivityCenter) -> [Color]? {
        activities.compactGlow(left: leftEarModule, right: rightEarModule)
    }
}

/// Значок второй активности в правом ухе компакта: кружок с её `bubble` (обложка, кольцо загрузки, значок агента)
/// или значком модуля.
enum SecondaryMark {
    /// Диаметр кружка и место, которое он добавляет уху (кружок + зазор до основной подписи).
    static let size: CGFloat = 18
    static let width: CGFloat = 24
}
