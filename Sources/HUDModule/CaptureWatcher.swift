import AppKit
import CoreAudio
import CoreMediaIO

/// Камера (CoreMediaIO `DeviceIsRunningSomewhere`) и микрофон. Только слушатели, без опроса; прав не нужно —
/// мы не открываем устройства, а читаем флаги.
///
/// Микрофон считаем включённым по **процессам** CoreAudio (`kAudioProcessPropertyIsRunningInput`, macOS 14+), а не по
/// `kAudioDevicePropertyDeviceIsRunningSomewhere`: тот флаг относится ко всему устройству, и у гарнитуры со входом
/// и выходом (USB-гарнитура, AirPods) он true, когда через неё просто играет музыка. Слушатели: список процессов
/// (`kAudioHardwarePropertyProcessObjectList`), `IsRunningInput` на каждом процессе и — как запасной триггер —
/// `DeviceIsRunningSomewhere` на входных устройствах (при нём состояние всё равно перечитывается по процессам).
/// Помощники аудиодрайверов (`/Library/Audio/Plug-Ins/…`) не считаются — см. `isAudioInfrastructure`.
@MainActor
final class CaptureWatcher {
    var onChange: ((_ camera: Bool, _ microphone: Bool, _ app: String?, _ rising: Bool) -> Void)?

    private enum Kind { case cameraList, camera, deviceList, device, processList, process }

    private(set) var cameraOn = false
    private(set) var micOn = false
    private var running = false
    private var cmioListeners: [(CMIOObjectID, CMIOObjectPropertyAddress, Kind)] = []
    private var audioListeners: [(AudioObjectID, AudioObjectPropertyAddress, Kind)] = []
    private var pending = false
    /// Сколько раз система не сняла слушатель (код возврата ≠ 0). Для самотеста: должно быть 0.
    private(set) var removeFailures = 0

    private lazy var cmioBlock: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.schedule() }
    }
    private lazy var cmioDevicesBlock: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.rebindCameras(); self?.schedule() }
    }
    private lazy var audioBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.schedule() }
    }
    private lazy var audioDevicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.rebindMics(); self?.schedule() }
    }
    private lazy var processListBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.rebindProcesses(); self?.schedule() }
    }

    var listenerCount: Int { cmioListeners.count + audioListeners.count }
    /// Слушателей на процессах CoreAudio (для самотеста).
    var processListenerCount: Int { audioListeners.filter { $0.2 == .process }.count }

    private func cmioBlock(for k: Kind) -> CMIOObjectPropertyListenerBlock {
        k == .cameraList ? cmioDevicesBlock : cmioBlock
    }

    private func audioBlock(for k: Kind) -> AudioObjectPropertyListenerBlock {
        switch k {
        case .deviceList: return audioDevicesBlock
        case .processList: return processListBlock
        default: return audioBlock
        }
    }

    func start() {
        guard !running else { return }
        running = true
        var devs = Self.cmioAddr(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        if CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &devs, .main, cmioDevicesBlock) == 0 {
            cmioListeners.append((CMIOObjectID(kCMIOObjectSystemObject), devs, .cameraList))
        }
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var adevs = AudioWatcher.addr(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal)
        if AudioObjectAddPropertyListenerBlock(sys, &adevs, .main, audioDevicesBlock) == noErr {
            audioListeners.append((sys, adevs, .deviceList))
        }
        var procs = AudioWatcher.addr(kAudioHardwarePropertyProcessObjectList, kAudioObjectPropertyScopeGlobal)
        if AudioObjectAddPropertyListenerBlock(sys, &procs, .main, processListBlock) == noErr {
            audioListeners.append((sys, procs, .processList))
        }
        rebindCameras()
        rebindMics()
        rebindProcesses()
        cameraOn = Self.cameraRunning()
        micOn = Self.micRunning()
    }

    func stop() {
        guard running else { return }
        running = false
        for (o, a, k) in cmioListeners { removeCMIO(o, a, k) }
        for (o, a, k) in audioListeners { removeAudio(o, a, k) }
        cmioListeners.removeAll(); audioListeners.removeAll()
        cameraOn = false; micOn = false
    }

    /// После сна / смены экранов / возврата сессии: слушатели на текущих камерах, входах и процессах заново и
    /// одно перечитывание состояния (камеру/микрофон могли выключить во сне — флаги и «живая точка» не залипнут).
    /// Изменилось — `onChange` как обычно; не изменилось — тихо.
    func rewire() {
        guard running else { return }
        rebindCameras()
        rebindMics()
        rebindProcesses()
        schedule()
    }

    private func removeCMIO(_ o: CMIOObjectID, _ a: CMIOObjectPropertyAddress, _ k: Kind) {
        var a = a
        let err = CMIOObjectRemovePropertyListenerBlock(o, &a, .main, cmioBlock(for: k))
        // Устройство уже исчезло (отключили камеру) — снимать нечего, это не утечка.
        if err != 0, k == .cameraList || Self.cameras().contains(o) { removeFailures += 1 }
    }

    private func removeAudio(_ o: AudioObjectID, _ a: AudioObjectPropertyAddress, _ k: Kind) {
        var a = a
        let err = AudioObjectRemovePropertyListenerBlock(o, &a, .main, audioBlock(for: k))
        guard err != noErr else { return }
        // Процесс завершился / устройство отключили — объекта больше нет, слушатель ушёл вместе с ним.
        let gone: Bool
        switch k {
        case .process: gone = !Self.processObjects().contains(o)
        case .device: gone = !AudioWatcher.allDevices().contains(o)
        default: gone = false
        }
        if !gone { removeFailures += 1 }
    }

    private func rebindCameras() {
        guard running else { return }
        for (o, a, k) in cmioListeners where k == .camera { removeCMIO(o, a, k) }
        cmioListeners.removeAll { $0.2 == .camera }
        for d in Self.cameras() {
            var a = Self.cmioAddr(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
            if CMIOObjectAddPropertyListenerBlock(d, &a, .main, cmioBlock) == 0 { cmioListeners.append((d, a, .camera)) }
        }
    }

    private func rebindMics() {
        guard running else { return }
        for (o, a, k) in audioListeners where k == .device { removeAudio(o, a, k) }
        audioListeners.removeAll { $0.2 == .device }
        for d in Self.inputDevices() {
            var a = AudioWatcher.addr(kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal)
            if AudioObjectAddPropertyListenerBlock(d, &a, .main, audioBlock) == noErr { audioListeners.append((d, a, .device)) }
        }
    }

    /// Список процессов CoreAudio изменился: снять слушатели с ушедших, повесить на новые.
    private func rebindProcesses() {
        guard running else { return }
        let now = Set(Self.processObjects())
        let bound = Set(audioListeners.filter { $0.2 == .process }.map(\.0))
        for (o, a, k) in audioListeners where k == .process && !now.contains(o) { removeAudio(o, a, k) }
        audioListeners.removeAll { $0.2 == .process && !now.contains($0.0) }
        for p in now.subtracting(bound) {
            var a = AudioWatcher.addr(kAudioProcessPropertyIsRunningInput, kAudioObjectPropertyScopeGlobal)
            if AudioObjectAddPropertyListenerBlock(p, &a, .main, audioBlock) == noErr { audioListeners.append((p, a, .process)) }
        }
    }

    /// Камера и микрофон часто включаются вместе — склеиваем в одну вспышку (0,35 с).
    private func schedule() {
        guard running, !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            MainActor.assumeIsolated {
                // Снять флаг до проверки `running`: иначе stop() в эти 0,35 с оставлял его поднятым навсегда,
                // и после нового start() камера/микрофон больше не перечитывались.
                guard let self else { return }
                self.pending = false
                guard self.running else { return }
                let cam = Self.cameraRunning(), mic = Self.micRunning()
                let rising = (cam && !self.cameraOn) || (mic && !self.micOn)
                let changed = cam != self.cameraOn || mic != self.micOn
                self.cameraOn = cam; self.micOn = mic
                if changed {
                    // Вспышка — только на включение; выключение тихо меняет состояние.
                    let apps = mic ? Self.micApps() : []
                    self.onChange?(cam, mic, Self.appLabel(apps), rising)
                }
            }
        }
    }

    static func appLabel(_ apps: [String]) -> String? {
        switch apps.count {
        case 0: return nil
        case 1: return apps[0]
        default: return apps[0] + " +\(apps.count - 1)"
        }
    }

    // MARK: CoreMediaIO

    nonisolated static func cmioAddr(_ sel: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: sel,
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    nonisolated static func cameras() -> [CMIOObjectID] {
        var a = cmioAddr(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        var size: UInt32 = 0
        let sys = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == 0, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(sys, &a, 0, nil, size, &used, &ids) == 0 else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    nonisolated static func cameraRunning() -> Bool {
        cameras().contains { d in
            var a = cmioAddr(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
            var v: UInt32 = 0
            var used: UInt32 = 0
            return CMIOObjectGetPropertyData(d, &a, 0, nil, 4, &used, &v) == 0 && v != 0
        }
    }

    // MARK: CoreAudio (вход)

    nonisolated static func inputDevices() -> [AudioObjectID] {
        AudioWatcher.allDevices().filter { AudioWatcher.hasStreams($0, scope: kAudioDevicePropertyScopeInput) }
    }

    /// Объекты процессов CoreAudio (macOS 14+). nil — свойство недоступно.
    nonisolated static func processObjectsOrNil() -> [AudioObjectID]? {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var a = AudioWatcher.addr(kAudioHardwarePropertyProcessObjectList, kAudioObjectPropertyScopeGlobal)
        var s = UInt32(0)
        guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &s) == noErr else { return nil }
        guard s > 0 else { return [] }
        var procs = [AudioObjectID](repeating: 0, count: Int(s) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &s, &procs) == noErr else { return nil }
        return Array(procs.prefix(Int(s) / MemoryLayout<AudioObjectID>.size))
    }

    nonisolated static func processObjects() -> [AudioObjectID] { processObjectsOrNil() ?? [] }

    nonisolated static func processIsRunningInput(_ p: AudioObjectID) -> Bool {
        var ra = AudioWatcher.addr(kAudioProcessPropertyIsRunningInput, kAudioObjectPropertyScopeGlobal)
        var running: UInt32 = 0
        var rs = UInt32(4)
        return AudioObjectGetPropertyData(p, &ra, 0, nil, &rs, &running) == noErr && running != 0
    }

    nonisolated static func processPID(_ p: AudioObjectID) -> pid_t? {
        var pa = AudioWatcher.addr(kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal)
        var pid: pid_t = 0
        var ps = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(p, &pa, 0, nil, &ps, &pid) == noErr ? pid : nil
    }

    /// Помощники аудиодрайверов (HAL-плагины: Rogue Amoeba ARK у SoundSource/Audio Hijack/Loopback, usbaudiod…)
    /// читают вход устройства, когда через него просто играет звук: проверено 14.11.2026 — тишина на
    /// «AB17X USB Audio» дала `IsRunningInput` у `arkaudiod`. Это не «кто-то пишет микрофон» — не считаем.
    nonisolated static func isAudioInfrastructure(pid: pid_t) -> Bool {
        guard let path = executablePath(pid: pid) else { return false }
        return path.hasPrefix("/Library/Audio/Plug-Ins/") || path.hasPrefix("/System/Library/Audio/Plug-Ins/")
            || path.hasPrefix("/usr/sbin/coreaudiod")
    }

    nonisolated static func executablePath(pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    /// Процесс пишет вход и это не помощник драйвера.
    nonisolated static func processRecords(_ p: AudioObjectID) -> Bool {
        guard processIsRunningInput(p) else { return false }
        // Сам остров не считается (18.11): захват звука системы для эквалайзера (process tap) у CoreAudio — «вход»,
        // и вспышка «SimpleIsland — микрофон» мигала под музыку. Свою запись с микрофона «Встречи» показывают сами.
        if let pid = processPID(p), pid == getpid() || isAudioInfrastructure(pid: pid) { return false }
        return true
    }

    /// Флаг всего устройства (вход и выход вместе) — только для самотеста и запасного пути.
    nonisolated static func deviceRunningSomewhere(_ d: AudioObjectID) -> Bool {
        var a = AudioWatcher.addr(kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal)
        var v: UInt32 = 0
        var s = UInt32(4)
        return AudioObjectGetPropertyData(d, &a, 0, nil, &s, &v) == noErr && v != 0
    }

    /// Микрофон пишет кто-то: есть процесс с `IsRunningInput`. Если список процессов недоступен — по флагу
    /// устройства, но только у устройств без выхода (иначе музыка в гарнитуре = «микрофон»).
    nonisolated static func micRunning() -> Bool {
        if let procs = processObjectsOrNil() { return procs.contains(where: processRecords) }
        return inputDevices()
            .filter { !AudioWatcher.hasStreams($0, scope: kAudioDevicePropertyScopeOutput) }
            .contains(where: deviceRunningSomewhere)
    }

    /// Имена приложений, что сейчас пишут звук с входа.
    nonisolated static func micApps() -> [String] {
        var names: [String] = []
        for p in processObjects() where processRecords(p) {
            var name = processPID(p).flatMap { appName(pid: $0) }
            if name == nil {
                var ba = AudioWatcher.addr(kAudioProcessPropertyBundleID, kAudioObjectPropertyScopeGlobal)
                var bid: Unmanaged<CFString>?
                var bs = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                if AudioObjectGetPropertyData(p, &ba, 0, nil, &bs, &bid) == noErr, let b = bid?.takeRetainedValue() as String?,
                   !b.isEmpty {
                    name = b.split(separator: ".").last.map(String.init)
                }
            }
            if let n = name, !names.contains(n) { names.append(n) }
        }
        return names
    }

    /// Имя приложения по pid; для помощников (WebKit, «… Helper») — имя родительского .app.
    nonisolated static func appName(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        if let url = app?.bundleURL {
            // Помощник внутри другого .app: …/Telegram.app/Contents/Frameworks/…/Helper.app → «Telegram».
            let comps = url.pathComponents
            if let i = comps.firstIndex(where: { $0.hasSuffix(".app") }), i < comps.count - 1 {
                return String(comps[i].dropLast(4))
            }
        }
        return app?.localizedName
    }
}
