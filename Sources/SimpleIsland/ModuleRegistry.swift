import IslandCore
import MediaModule
import HUDModule
import ShelfModule
import AgentsModule
import TodayModule
import VafaModule   // --- catalog ---
import MenuBarModule   // --- menubar ---
#if SIMPLEISLAND_MEETINGS
import MeetingsModule   // --- meetings ---
#endif

/// Список модулей острова. Порядок = порядок вкладок по умолчанию.
/// Новый модуль: таргет в Package.swift (islandModules) + import выше + строка здесь.
@MainActor
enum ModuleRegistry {
    static func makeModules() -> [IslandModule] {
        let media = MediaIslandModule()
        var list: [IslandModule] = [
            media,
            TodayIslandModule(),
            ShelfIslandModule(),
            AgentsIslandModule(),
            HUDIslandModule(),
            VafaIslandModule(),   // --- catalog --- по умолчанию выключен, включается из каталога виджетов
            MenuBarIslandModule(),   // --- menubar --- вкладка «Значки»: уборка строки меню
            media.equalizerModule,   // --- lyrics --- виджет «Эквалайзер» на модели «Медиа», по умолчанию выключен
        ]
#if SIMPLEISLAND_MEETINGS
        list.append(MeetingsIslandModule())   // Sten, off by default
#endif
        return list
    }
}
