import AppKit
import SwiftUI
import IslandCore

/// Буфер обмена: последние записи карточками (код — моноширинным, цвет — образцом), клик — скопировать обратно.
struct ClipboardTile: View {
    @ObservedObject var model: TodayModel
    @Environment(\.islandTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        Tile {
            VStack(alignment: .leading, spacing: 10) {
                TileLabel("Буфер обмена", systemImage: "clipboard") {
                    if !model.clips.isEmpty {
                        Button { model.clearClipboard() } label: {
                            Text("Очистить").font(theme.font(10.5, .semibold)).foregroundStyle(theme.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Забыть историю буфера")
                    }
                }
                if model.clips.isEmpty {
                    Text("Скопируй что-нибудь — появится здесь. Пароли из менеджеров паролей не записываются.")
                        .font(theme.font(11.5, .medium)).foregroundStyle(theme.tertiary).lineLimit(3)
                    Spacer(minLength: 0)
                } else {
                    GeometryReader { g in
                        let n = max(1, min(model.clips.count, Int((g.size.width + 8) / 80)))
                        let w = (g.size.width - 8 * CGFloat(n - 1)) / CGFloat(n)
                        if isSnapshot || model.clips.count <= n {
                            HStack(spacing: 8) { cards(model.clips.prefix(n), width: w) }
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) { cards(model.clips[...], width: w) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func cards(_ items: ArraySlice<ClipItem>, width: CGFloat) -> some View {
        ForEach(items) { item in
            ClipCard(item: item, now: model.now, copied: model.copiedId == item.id, showSource: width >= 110)
                .frame(width: width)
                .onTapGesture { model.copy(item) }
                .help([item.source, "щёлкни — скопировать снова"].compactMap { $0 }.joined(separator: " · "))
        }
    }
}

struct ClipCard: View {
    var item: ClipItem
    var now: Date
    var copied: Bool
    /// Узкая карточка — только время (источник — в подсказке).
    var showSource = true
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let swatch = item.colorHex.flatMap { NSColor(hex: $0) }
        let onSwatch: Color = swatch.map { $0.luminance > 0.6 ? Color.black : Color.white } ?? theme.primary
        VStack(alignment: .leading, spacing: 0) {
            content(swatch: swatch, onSwatch: onSwatch)
            Spacer(minLength: 2)
            Group {
                if copied {
                    Text("Скопировано").foregroundStyle(swatch != nil ? onSwatch.opacity(0.8) : IslandPalette.okText(theme))
                } else {
                    // Источник сжимается первым, время видно всегда.
                    HStack(spacing: 0) {
                        let src = showSource ? item.source : nil
                        if let s = src { Text(s).lineLimit(1).truncationMode(.tail) }
                        Text((src == nil ? "" : " · ") + ClipRules.age(item.date, now: now)).fixedSize()
                    }
                    .foregroundStyle(swatch != nil ? onSwatch.opacity(0.7) : theme.quaternary)
                }
            }
            .font(theme.font(9.5, .medium))
            .lineLimit(1)
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background(swatch))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private func content(swatch: NSColor?, onSwatch: Color) -> some View {
        switch item.kind {
        case .color:
            Text(item.colorHex ?? item.text).font(theme.font(12.5, .bold)).foregroundStyle(onSwatch).lineLimit(1)
        case .code:
            Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(theme.isLight ? Color(hex: "#1F5FA8") : Color(hex: "#9FD3FF"))
                .lineSpacing(1.5).lineLimit(3)
        case .url:
            let u = URL(string: item.text.trimmingCharacters(in: .whitespacesAndNewlines))
            VStack(alignment: .leading, spacing: 1) {
                Text(u?.host?.replacingOccurrences(of: "www.", with: "") ?? item.text).lineLimit(1)
                Text(u.map { String(($0.path + ($0.query.map { "?" + $0 } ?? "")).drop { $0 == "/" }) } ?? "").lineLimit(2)
                    .foregroundStyle(theme.tertiary)
            }
            .font(theme.font(10.5, .medium)).foregroundStyle(theme.secondary)
        case .image:
            if let img = item.thumbnail {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: 40).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Label("Изображение", systemImage: "photo").font(theme.font(10.5, .medium)).foregroundStyle(theme.secondary)
            }
        case .file:
            Label { Text(item.text).lineLimit(2) } icon: { Image(systemName: "doc") }
                .font(theme.font(10.5, .medium)).foregroundStyle(theme.secondary)
        case .text:
            Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(theme.font(10.5, .medium)).foregroundStyle(theme.secondary).lineLimit(3)
        }
    }

    @ViewBuilder private func background(_ swatch: NSColor?) -> some View {
        if let s = swatch {
            let base = Color(nsColor: s)
            // Как в макете (#FF7A45 → #FF3D7F): тот же цвет с оттенком, сдвинутым на ~20°.
            let c = s.usingColorSpace(.sRGB) ?? s
            let hue = c.hueComponent - 0.055
            let shifted = Color(nsColor: NSColor(hue: hue < 0 ? hue + 1 : hue, saturation: c.saturationComponent,
                                                 brightness: c.brightnessComponent, alpha: 1))
            LinearGradient(colors: [base, shifted], startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            theme.innerFill
        }
    }
}
