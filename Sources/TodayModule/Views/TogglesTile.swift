@preconcurrency import AVFoundation
import AppKit
import SwiftUI
import IslandCore

/// «Быстрое»: сетка тумблеров 3×2. На время подтверждения/просьбы о праве/зеркала сетку заменяет панель.
struct TogglesTile: View {
    @ObservedObject var model: TodayModel
    @ObservedObject var mirror: CameraMirror
    @Environment(\.islandTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        Tile {
            VStack(alignment: .leading, spacing: 9) {
                TileLabel(model.mirrorOn ? "Зеркало" : "Быстрое", systemImage: model.mirrorOn ? "camera" : "bolt") {
                    if let err = model.toggleError {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(IslandPalette.warmText(theme)).help(err)
                    }
                }
                if let p = model.permissionPrompt ?? (model.mirrorOn && mirror.state == .needsPermission ? .camera : nil) {
                    PermissionNotice(title: p.shortTitle, note: note(for: p), compact: true) {
                        // Окно macOS или раздел настроек + карточка «где включить» (ядро, не молчит).
                        Task { @MainActor in _ = await Permissions.requestFromUser(p.islandPermission, moduleId: "today") }
                    } dismiss: {
                        model.permissionPrompt = nil
                        if model.mirrorOn { model.toggle(.mirror) }
                    }
                } else if model.confirmCleanDesk {
                    confirm
                } else if model.mirrorOn {
                    mirrorView
                } else {
                    grid
                }
            }
        }
    }

    private func note(for p: TodayPermission) -> String {
        switch p {
        case .automation: return "Тёмной теме нужно право на System Events."
        case .camera: return "Камера включается, только пока плитка открыта."
        case .calendar: return "Нужен доступ к календарю."
        }
    }

    private var grid: some View {
        let items = model.availableToggles
        let rows = stride(from: 0, to: items.count, by: 3).map { Array(items[$0..<min($0 + 3, items.count)]) }
        return VStack(spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(row) { k in cell(k) }
                    ForEach(0..<(3 - row.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 38) }
                }
            }
        }
    }

    private func cell(_ k: ToggleKind) -> some View {
        let on = model.isOn(k)
        let fg: Color = on ? (theme.isLight ? .white : .black) : theme.primary
        return Button { model.toggle(k) } label: {
            VStack(spacing: 3) {
                Image(systemName: k == .mic && on ? "mic.slash.fill" : k.symbol).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(fg)
                Text(k.title).font(theme.font(9, .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundStyle(on ? fg.opacity(0.65) : theme.tertiary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(on ? theme.primary : theme.innerFill))
            .opacity(model.busy.contains(k) ? 0.5 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .help(k.help)
    }

    private var confirm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.desktopHidden ? "Вернуть значки на стол?" : "Спрятать значки стола?")
                .font(theme.font(13, .bold)).foregroundStyle(theme.primary)
            Text("Finder перезапустится — его окна на миг пропадут.")
                .font(theme.font(11, .medium)).foregroundStyle(theme.tertiary).lineLimit(2)
            HStack(spacing: 6) {
                IslandButton(model.desktopHidden ? "Вернуть" : "Спрятать", style: .solid, height: 26) { model.confirmCleanDesk(true) }
                IslandButton("Отмена", height: 26) { model.confirmCleanDesk(false) }
            }
        }
    }

    private var mirrorView: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if isSnapshot || mirror.state != .running {
                    ZStack {
                        theme.innerFill
                        Image(systemName: "person.crop.square").font(.system(size: 22)).foregroundStyle(theme.tertiary)
                    }
                } else {
                    CameraPreview(session: mirror.session)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            IslandButton(systemImage: "xmark", height: 22) { model.toggle(.mirror) }
                .padding(5)
        }
    }
}

/// Превью камеры (зеркально). NSView — в снимках не рисуется, там заглушка.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        if let c = layer.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
        }
        layer.frame = v.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        v.layer?.addSublayer(layer)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
