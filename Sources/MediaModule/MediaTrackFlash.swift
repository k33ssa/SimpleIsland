import AppKit
import IslandCore
import SwiftUI

// Вспышка «новый трек» (UX 15.11, политика уведомлений): по умолчанию ВЫКЛ — компакт и так обновится сам.
// Включена — короткая вспышка в ушах: слева обложка + название, справа исполнитель. Без названия — ничего
// (вспышка «значок без текста» ни о чём не говорит; ядро такие и не покажет).

enum MediaTrackFlash {
    /// Сколько знаков названия и исполнителя влезает в ухо.
    static let titleChars = 22
    static let artistChars = 20

    /// Показывать ли вспышку на смену трека `old` → `new`. Правила:
    /// включено в настройках; это именно смена трека (не первое появление, не тот же трек); играет; приложение
    /// работает дольше 3 с; вкладка «Медиа» не открыта (там и так видно); есть название.
    static func shouldFlash(enabled: Bool, old: NowPlaying?, new: NowPlaying?, uptime: TimeInterval, tabVisible: Bool) -> Bool {
        guard enabled, let old, let new, old.trackKey != new.trackKey, new.isPlaying, uptime > 3, !tabVisible else { return false }
        return !new.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    static func event(model: MediaModel, track n: NowPlaying) -> HUDEvent {
        let title = ToolClip.clip(n.title, titleChars)
        let artist = ToolClip.clip(n.artist.isEmpty ? (n.appName ?? "") : n.artist, artistChars)
        // Ширина уха: обложка 20 + отступ 7 + название (~7 pt на знак 12,5 bold) и поля; не шире 190.
        let side = min(190, max(120, CGFloat(max(title.count * 7 + 27, artist.count * 7)) + 30))
        var e = HUDEvent(kind: "media.track", sideWidth: side,
                         customLeading: AnyView(TrackFlashLeading(model: model, title: title)),
                         customTrailing: artist.isEmpty ? nil : AnyView(TrackFlashTrailing(text: artist)))
        e.accessibilityLabel = "Играет: " + [n.artist, n.title].filter { !$0.isEmpty }.joined(separator: " — ")
        return e
    }
}

/// Обрезка с «…» без зависимостей от других модулей.
enum ToolClip {
    static func clip(_ s: String, _ n: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > n ? String(t.prefix(n - 1)) + "…" : t
    }
}

/// Левое ухо: обложка (подтянется, когда догрузится) + название.
struct TrackFlashLeading: View {
    @ObservedObject var model: MediaModel
    var title: String
    @Environment(\.islandTheme) private var theme
    var body: some View {
        HStack(spacing: 7) {
            CoverView(image: model.coverImage, placeholder: model.placeholderArtwork, size: 20, radius: theme.mediaRadius(5),
                      shadow: nil, appBadge: nil, videoIcon: model.now?.isVideo == true)
            Text(title).font(theme.font(12.5, .bold)).foregroundStyle(theme.primary).lineLimit(1)
        }
    }
}

/// Правое ухо: исполнитель.
struct TrackFlashTrailing: View {
    var text: String
    @Environment(\.islandTheme) private var theme
    var body: some View {
        Text(text).font(theme.font(12.5, .semibold)).foregroundStyle(theme.secondary).lineLimit(1)
    }
}
