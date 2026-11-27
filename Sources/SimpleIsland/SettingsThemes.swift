import AppKit
import SwiftUI
import UniformTypeIdentifiers
import IslandCore

// «Темы»: галерея всех тем с живыми мини-превью (настоящие IslandBackground, Pill, ArtworkView в цветах темы),
// применение кликом, папка тем, импорт JSON, копия для правки.

/// Файловые операции с темами (каталог — параметр, чтобы самотест писал во временную папку).
enum ThemeFiles {
    enum Failure: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self { case .unreadable(let s): return s }
        }
    }

    /// Поля схемы темы (кроме id/name/subtitle): хотя бы одно должно быть в файле, иначе это не тема.
    static let themeFields: Set<String> = ["background", "rim", "glow", "text", "accent", "accent2", "controlFill",
                                           "font", "shape", "effects", "spring"]

    /// Результат импорта: тема (с итоговым id) и прежний id, если пришлось переименовать.
    struct Imported {
        var theme: Theme
        var renamedFrom: String?
    }

    /// Проверить JSON темы и положить его в `dir` как `<id>.json` (текст файла — как есть, с комментариями).
    /// Тема с таким id уже есть (встроенная, в `existingIds`, или файл в `dir`) — не перезаписываем, а кладём
    /// под `<id>-2`, `<id>-3`… (тогда файл пишется заново, без комментариев).
    @discardableResult
    static func importTheme(from url: URL, into dir: URL, existingIds: Set<String> = []) throws -> Imported {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw Failure.unreadable("Файл не читается: \(url.lastPathComponent)") }
        guard let raw = (try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])) as? [String: Any] else {
            throw Failure.unreadable("Это не тема SimpleIsland: \(url.lastPathComponent) — JSON не разобран")
        }
        let named = (raw["id"] as? String).map { !$0.isEmpty } == true || (raw["name"] as? String).map { !$0.isEmpty } == true
        guard named, !themeFields.isDisjoint(with: raw.keys) else {
            throw Failure.unreadable("Это не тема SimpleIsland: \(url.lastPathComponent) — нужны id или name и хотя бы одно поле темы (accent, background, text…)")
        }
        var theme: Theme
        do { theme = try Theme.decode(data, fallbackId: url.deletingPathExtension().lastPathComponent) }
        catch { throw Failure.unreadable("Это не тема SimpleIsland: \(url.lastPathComponent) — JSON не разобран") }
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let baseId = sanitize(theme.id)
        var safeId = baseId
        let source = url.standardizedFileURL
        func taken(_ id: String) -> Bool {
            let f = dir.appendingPathComponent("\(id).json")
            if f.standardizedFileURL == source { return false }   // перечитываем тот же файл из папки тем
            return existingIds.contains(id) || fm.fileExists(atPath: f.path)
        }
        var n = 2
        while taken(safeId) { safeId = "\(baseId)-\(n)"; n += 1 }
        let dest = dir.appendingPathComponent("\(safeId).json")
        if safeId != theme.id {
            var patched = raw
            patched["id"] = safeId
            if safeId != baseId { patched["name"] = "\(theme.name) (\(n - 1))" }
            try JSONSerialization.data(withJSONObject: patched, options: [.prettyPrinted, .sortedKeys]).write(to: dest, options: .atomic)
            let renamed = safeId != baseId ? theme.id : nil
            theme.id = safeId
            if safeId != baseId { theme.name = "\(theme.name) (\(n - 1))" }
            return Imported(theme: theme, renamedFrom: renamed)
        }
        if dest.standardizedFileURL != source {
            try data.write(to: dest, options: .atomic)
        }
        return Imported(theme: theme, renamedFrom: nil)
    }

    /// Копия темы с новым id (`<id>-copy`, `<id>-copy-2`…) в `dir`. Возвращает тему и путь к файлу.
    static func makeCopy(of theme: Theme, into dir: URL, existingIds: Set<String>) throws -> (Theme, URL) {
        var copy = theme
        let base = sanitize(theme.id) + "-copy"
        var id = base
        var n = 2
        let fm = FileManager.default
        while existingIds.contains(id) || fm.fileExists(atPath: dir.appendingPathComponent("\(id).json").path) {
            id = "\(base)-\(n)"; n += 1
        }
        copy.id = id
        copy.name = theme.name + " — копия"
        copy.subtitle = "своя"
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(id).json")
        try copy.encoded().write(to: url, options: .atomic)
        return (copy, url)
    }

    static func sanitize(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let s = String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return s.isEmpty ? "theme" : s
    }
}

struct ThemesSection: View {
    @ObservedObject var settings: SimpleIslandSettings
    @ObservedObject var themes: ThemeStore
    @State private var message: (String, Bool)?
    @Environment(\.settingsPalette) private var p

    var body: some View {
        SettingsHeader(title: "Темы",
                       subtitle: "Тема меняет материал, кромку, шрифт и физику, но не раскладку. Свои темы — JSON в папке тем.")
        FlowRows(spacing: 8) {
            SettingsButton(title: "Открыть папку тем", systemImage: "folder") {
                try? FileManager.default.createDirectory(at: SimpleIslandPaths.userThemes, withIntermediateDirectories: true)
                NSWorkspace.shared.open(SimpleIslandPaths.userThemes)
            }
            SettingsButton(title: "Импортировать JSON…", systemImage: "square.and.arrow.down") { importTheme() }
            SettingsButton(title: "Сделать копию для правки", systemImage: "plus.square.on.square") { duplicate() }
            SettingsButton(title: "Перечитать", systemImage: "arrow.clockwise", style: .quiet) { themes.reload() }
        }
        if let message {
            Text(message.0).font(p.font(12, .medium))
                .foregroundStyle(message.1 ? SettingsColors.err(p) : SettingsColors.ok(p))
        }
        if !themes.loadErrors.isEmpty {
            Text("Не разобраны: \(themes.loadErrors.keys.sorted().joined(separator: ", "))")
                .font(p.font(12, .medium)).foregroundStyle(SettingsColors.err(p))
        }
        ThemeGrid(themes: themes.themes, selectedId: themes.current.id, columns: 4, cardHeight: 118) { t in
            settings.data.themeId = t.id
        }
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.json]
        panel.allowsMultipleSelection = true
        panel.message = "Выбери JSON-файл темы SimpleIsland"
        panel.prompt = "Импортировать"
        // Раскрытый остров — свернуть: окно выбора ниже ловушки кликов (её прячет и правило «наше окно ключевое»).
        SettingsWindows.shared.env?.openTabHandler(nil)
        guard panel.runModal() == .OK else { return }
        var last: ThemeFiles.Imported?
        var errors: [String] = []
        var ids = Set(themes.themes.map(\.id))
        for url in panel.urls {
            do {
                let r = try ThemeFiles.importTheme(from: url, into: SimpleIslandPaths.userThemes, existingIds: ids)
                ids.insert(r.theme.id)
                last = r
            } catch { errors.append(error.localizedDescription) }
        }
        themes.reload()
        if let last {
            settings.data.themeId = last.theme.id
            let renamed = last.renamedFrom.map { " Тема с id «\($0)» уже была — новая сохранена как «\(last.theme.id)»." } ?? ""
            message = ("Тема «\(last.theme.name)» добавлена и включена.\(renamed)", false)
        }
        if !errors.isEmpty { message = (errors.joined(separator: "\n"), true) }
    }

    private func duplicate() {
        do {
            let current = settings.data.applying(to: themes.current)
            let (copy, url) = try ThemeFiles.makeCopy(of: current, into: SimpleIslandPaths.userThemes,
                                                      existingIds: Set(themes.themes.map(\.id)))
            themes.reload()
            settings.data.themeId = copy.id
            NSWorkspace.shared.activateFileViewerSelecting([url])
            message = ("Копия «\(copy.name)» — \(url.lastPathComponent). Правь JSON и нажми «Перечитать».", false)
        } catch {
            message = ("Не удалось сделать копию: \(error.localizedDescription)", true)
        }
    }
}

/// Сетка карточек тем (без Lazy-контейнеров — так она видна и в снимках).
struct ThemeGrid: View {
    var themes: [Theme]
    var selectedId: String
    var columns: Int
    var cardHeight: CGFloat
    var showsSubtitle = true
    var onSelect: (Theme) -> Void

    var body: some View {
        let rows = stride(from: 0, to: themes.count, by: columns).map { Array(themes[$0..<min($0 + columns, themes.count)]) }
        VStack(spacing: 14) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(alignment: .top, spacing: 14) {
                    ForEach(rows[r]) { t in
                        ThemeCard(theme: t, selected: t.id == selectedId, height: cardHeight, showsSubtitle: showsSubtitle)
                            .frame(maxWidth: .infinity)
                            .onTapGesture { onSelect(t) }
                    }
                    ForEach(0..<(columns - rows[r].count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
            }
        }
    }
}

/// Карточка темы: кусок «экрана» с раскрытым островом в этой теме (настоящие компоненты, уменьшенные).
struct ThemeCard: View {
    var theme: Theme
    var selected: Bool
    var height: CGFloat = 118
    var showsSubtitle = true
    @Environment(\.settingsPalette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { g in
                let scale = min(g.size.width / 380, height / 200)
                ZStack(alignment: .top) {
                    LinearGradient(colors: [Color(hex: "#2A1550"), Color(hex: "#5B1A4A"), Color(hex: "#8A3A1C")],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    MiniIsland(theme: theme)
                        .frame(width: 380, height: 200, alignment: .top)
                        .scaleEffect(scale, anchor: .top)
                        .frame(width: g.size.width, height: g.size.height, alignment: .top)
                }
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? p.accent : p.hair, lineWidth: selected ? 2.5 : 1))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 16, weight: .bold))
                        .foregroundStyle(p.onAccent, p.accent)
                        .padding(7)
                }
            }
            HStack(spacing: 6) {
                Text(theme.name).font(p.font(13, .semibold)).foregroundStyle(p.ink).lineLimit(1)
                if showsSubtitle {
                    Text(theme.subtitle).font(p.font(11.5)).foregroundStyle(p.ink3).lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

/// Раскрытый остров 340×150 в теме: вкладки, обложка, название, полоса. Рисуется в полном размере и уменьшается.
private struct MiniIsland: View {
    var theme: Theme
    var body: some View {
        let m = IslandMetrics(width: 340, height: 150, cornerRadius: CGFloat(theme.shape.cornerRadius) * 0.8,
                              earRadius: CGFloat(theme.shape.earRadius) * 0.8)
        ZStack(alignment: .top) {
            if theme.glow.source != .none {
                IslandGlow(colors: theme.glow.source == .fixed ? theme.glowColors : ArtworkView.glowColors(for: .warm),
                           metrics: m, opacity: theme.glow.opacity * 0.8, radius: theme.glow.radius * 0.6)
            }
            IslandBackground(metrics: m, coreHeight: 30)
                .frame(width: m.outerWidth, height: m.height)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 2) {
                    Pill("Медиа", systemImage: "music.note", selected: true).fixedSize()
                    Pill("Сегодня", systemImage: "calendar").fixedSize()
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 12) {
                    ArtworkView(cornerRadius: 12).frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Полуночный трамвай").font(theme.font(15, .bold)).foregroundStyle(theme.primary).lineLimit(1)
                        Text("Северный ветер").font(theme.font(12, .medium)).foregroundStyle(theme.secondary).lineLimit(1)
                        ProgressTrack(value: 0.46, height: 4, tint: AnyShapeStyle(theme.accentColor))
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 4)
            .frame(width: m.width, height: m.height, alignment: .top)
            // Физический вырез.
            UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9).fill(.black)
                .frame(width: 90, height: 30)
        }
        .environment(\.islandTheme, theme)
        .environment(\.isSnapshot, true) // превью статичные: без бегущей рамки, стекло — имитация
    }
}
