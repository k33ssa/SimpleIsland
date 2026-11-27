import Foundation
import SwiftUI

/// Список тем и текущая тема.
/// Порядок загрузки (позже — важнее, совпадение id перекрывает): встроенная obsidian →
/// Contents/Resources/Themes → ~/Library/Application Support/SimpleIsland/Themes → `extraDirectories`.
@MainActor
public final class ThemeStore: ObservableObject {
    @Published public private(set) var themes: [Theme] = [.obsidian]
    @Published public private(set) var current: Theme = .obsidian
    /// Ошибки разбора файлов (имя файла → текст), чтобы показать в настройках.
    @Published public private(set) var loadErrors: [String: String] = [:]

    public var extraDirectories: [URL]

    public init(extraDirectories: [URL] = [], load: Bool = true) {
        self.extraDirectories = extraDirectories
        if load { reload() }
    }

    public var directories: [URL] {
        [SimpleIslandPaths.bundledThemes, SimpleIslandPaths.userThemes].compactMap { $0 } + extraDirectories
    }

    public func reload() {
        var byId: [String: Theme] = [Theme.obsidian.id: .obsidian]
        var order: [String] = [Theme.obsidian.id]
        var errors: [String: String] = [:]
        let fm = FileManager.default
        for dir in directories {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where url.pathExtension.lowercased() == "json" {
                do {
                    let theme = try Theme.decode(Data(contentsOf: url),
                                                 fallbackId: url.deletingPathExtension().lastPathComponent)
                    if byId[theme.id] == nil { order.append(theme.id) }
                    byId[theme.id] = theme
                } catch {
                    errors[url.lastPathComponent] = "\(error)"
                }
            }
        }
        themes = order.compactMap { byId[$0] }
        loadErrors = errors
        current = byId[current.id] ?? .obsidian
    }

    public func theme(id: String) -> Theme? { themes.first { $0.id == id } }

    /// Выбрать тему по id; неизвестный id → obsidian.
    public func select(_ id: String) {
        current = theme(id: id) ?? .obsidian
    }
}
