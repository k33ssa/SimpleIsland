import Combine
import Foundation

// --- keys --- мост «медиаклавиши → музыка» между модулями: event tap живёт в HUD (Универсальный доступ, один на
// процесс), решение «кому отдать ⏯ ⏭ ⏮» — в «Медиа» (знает, что играет и где играла музыка). Модули друг о друге не
// знают: HUD спрашивает мост, «Медиа» отвечает через него (docs/ARCHITECTURE.md, «Медиаклавиши»).

/// Клавиша управления воспроизведением (NX keytype: PLAY 16; NEXT 17 / FAST 19; PREVIOUS 18 / REWIND 20).
public enum MediaTransportKey: String, Sendable, CaseIterable {
    case playPause, next, previous
}

/// Нажатие клавиши управления: нажата, автоповтор (держат), отпущена.
public struct MediaTransportPress: Equatable, Sendable {
    public enum Phase: String, Sendable { case down, repeating, up }
    public var key: MediaTransportKey
    public var phase: Phase
    public init(key: MediaTransportKey, phase: Phase) { self.key = key; self.phase = phase }
}

@MainActor
public final class MediaKeyRouter: ObservableObject {
    public static let shared = MediaKeyRouter()

    /// Кто-то («Медиа») хочет получать клавиши управления — HUD держит tap активным (глотающим) даже без замены
    /// системного HUD. Меняет только владелец обработчика.
    @Published public private(set) var wantsKeys = false
    /// Tap запущен в активном режиме (HUD сообщает) — для подсказки в настройках «Медиа».
    @Published public private(set) var tapActive = false
    private var owner: String?
    private var handler: ((MediaTransportPress) -> Bool)?
    /// Сколько нажатий прошло через мост (самотест).
    public private(set) var handled = 0

    public init() {}

    /// Подключить обработчик. `wants` — нужны ли клавиши сейчас (настройка «Медиаклавиши управляют музыкой»).
    public func register(owner: String, wants: Bool, handler: @escaping (MediaTransportPress) -> Bool) {
        self.owner = owner
        self.handler = handler
        if wantsKeys != wants { wantsKeys = wants }
    }

    public func setWants(_ wants: Bool, owner: String) {
        guard self.owner == owner, wantsKeys != wants else { return }
        wantsKeys = wants
    }

    public func unregister(owner: String) {
        guard self.owner == owner else { return }
        self.owner = nil
        handler = nil
        if wantsKeys { wantsKeys = false }
    }

    /// HUD: состояние tap (активный — клавиши можно глотать).
    public func setTapActive(_ on: Bool) { if tapActive != on { tapActive = on } }

    /// Отдать нажатие. true — клавиша взята (HUD её глотает, отпускание — тоже). Нет обработчика / не нужны — false.
    public func handle(_ press: MediaTransportPress) -> Bool {
        guard wantsKeys, let handler else { return false }
        handled += 1
        return handler(press)
    }
}
